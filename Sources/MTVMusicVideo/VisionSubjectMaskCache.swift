import CoreImage
import Foundation
import ImageIO
import Vision

struct VisionLayoutProfile: Sendable, Equatable {
    let subjectBounds: CGRect
    let subjectCenter: CGPoint
    let coverage: CGFloat

    var supportsSpatialComposition: Bool {
        coverage >= 0.015
            && coverage <= 0.68
            && subjectBounds.width <= 0.94
            && subjectBounds.height <= 0.94
    }
}

/// Builds a reusable protection mask for each imported still image. Vision runs
/// once during import (or lazily on the first render), never in the frame loop.
final class VisionSubjectMaskCache: @unchecked Sendable {
    static let shared = VisionSubjectMaskCache()

    private let lock = NSLock()
    private var memory: [String: CGImage] = [:]
    private var profiles: [String: VisionLayoutProfile] = [:]
    private var profileMisses: Set<String> = []
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let maskSize = 256

    private init() {}

    func prewarm(url: URL) {
        let key = cacheKey(for: url)
        if cached(key: key) != nil { return }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              let mask = analyze(image, orientation: imageOrientation(source: source)) else { return }
        store(mask, key: key)
    }

    func mask(for identifier: String?, image: CGImage) -> CGImage? {
        guard let identifier else { return nil }
        let url = URL(fileURLWithPath: identifier)
        let key = cacheKey(for: url)
        if let existing = cached(key: key) { return existing }
        guard let mask = analyze(image, orientation: .up) else { return nil }
        store(mask, key: key)
        return mask
    }

    func layoutProfile(for identifier: String?, image: CGImage) -> VisionLayoutProfile? {
        guard let identifier else { return nil }
        let key = cacheKey(for: URL(fileURLWithPath: identifier))
        lock.lock()
        if let profile = profiles[key] {
            lock.unlock()
            return profile
        }
        if profileMisses.contains(key) {
            lock.unlock()
            return nil
        }
        lock.unlock()
        guard let mask = mask(for: identifier, image: image), let profile = Self.layoutProfile(from: mask) else {
            lock.lock()
            profileMisses.insert(key)
            lock.unlock()
            return nil
        }
        lock.lock()
        profiles[key] = profile
        lock.unlock()
        return profile
    }

    private func analyze(_ image: CGImage, orientation: CGImagePropertyOrientation) -> CGImage? {
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        let faces = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation)
        var foregroundImage: CGImage?
        if #available(macOS 14.0, *) {
            let foreground = VNGenerateForegroundInstanceMaskRequest()
            try? handler.perform([foreground, saliency, faces])
            if let observation = foreground.results?.first,
               let buffer = try? observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler) {
                foregroundImage = saliencyCGImage(from: buffer)
            }
        } else {
            try? handler.perform([saliency, faces])
        }
        let saliencyImage = foregroundImage ?? saliency.results?.first.flatMap { saliencyCGImage(from: $0.pixelBuffer) }
        return composeMask(saliencyImage: saliencyImage, faceBoxes: (faces.results ?? []).map(\.boundingBox))
    }

    func composeMask(saliencyImage: CGImage?, faceBoxes: [CGRect]) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: maskSize,
            height: maskSize,
            bitsPerComponent: 8,
            bytesPerRow: maskSize,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: maskSize, height: maskSize))

        if let saliencyImage {
            context.saveGState()
            context.setBlendMode(.lighten)
            context.interpolationQuality = .high
            context.draw(saliencyImage, in: CGRect(x: 0, y: 0, width: maskSize, height: maskSize))
            context.restoreGState()
        }

        context.saveGState()
        context.setBlendMode(.lighten)
        context.setFillColor(gray: 1, alpha: 1)
        for box in faceBoxes {
            let paddingX = box.width * 0.55
            let paddingY = box.height * 0.60
            let expanded = CGRect(
                x: (box.minX - paddingX) * CGFloat(maskSize),
                y: (box.minY - paddingY) * CGFloat(maskSize),
                width: (box.width + paddingX * 2) * CGFloat(maskSize),
                height: (box.height + paddingY * 2) * CGFloat(maskSize)
            )
            context.fillEllipse(in: expanded)
        }
        context.restoreGState()
        guard let rawMask = context.makeImage() else { return nil }

        let input = CIImage(cgImage: rawMask)
        let softened = input
            .applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1.45,
                kCIInputBrightnessKey: 0.05
            ])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 7.5])
            .cropped(to: input.extent)
        return ciContext.createCGImage(softened, from: input.extent)
    }

    static func layoutProfile(from mask: CGImage) -> VisionLayoutProfile? {
        let width = mask.width
        let height = mask.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let rendered = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return false }
            context.draw(mask, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        var weightedX: CGFloat = 0
        var weightedY: CGFloat = 0
        var totalWeight: CGFloat = 0
        for y in 0..<height {
            for x in 0..<width {
                let value = CGFloat(pixels[y * width + x]) / 255
                guard value > 0.18 else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
                weightedX += CGFloat(x) * value
                weightedY += CGFloat(y) * value
                totalWeight += value
            }
        }
        guard maxX >= minX, maxY >= minY, totalWeight > CGFloat(width * height) * 0.008 else { return nil }
        let bounds = CGRect(
            x: CGFloat(minX) / CGFloat(width),
            y: 1 - CGFloat(maxY + 1) / CGFloat(height),
            width: CGFloat(maxX - minX + 1) / CGFloat(width),
            height: CGFloat(maxY - minY + 1) / CGFloat(height)
        )
        return VisionLayoutProfile(
            subjectBounds: bounds,
            subjectCenter: CGPoint(x: weightedX / totalWeight / CGFloat(width), y: 1 - weightedY / totalWeight / CGFloat(height)),
            coverage: min(1, totalWeight / CGFloat(width * height))
        )
    }

    private func imageOrientation(source: CGImageSource) -> CGImagePropertyOrientation {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let raw = properties[kCGImagePropertyOrientation] as? UInt32,
              let orientation = CGImagePropertyOrientation(rawValue: raw) else { return .up }
        return orientation
    }

    private func saliencyCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1.8,
                kCIInputBrightnessKey: 0.08
            ])
        return ciContext.createCGImage(image, from: image.extent)
    }

    private func cached(key: String) -> CGImage? {
        lock.lock()
        if let image = memory[key] {
            lock.unlock()
            return image
        }
        lock.unlock()
        let url = diskURL(for: key)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true] as CFDictionary) else { return nil }
        lock.lock()
        memory[key] = image
        lock.unlock()
        return image
    }

    private func store(_ image: CGImage, key: String) {
        lock.lock()
        memory[key] = image
        lock.unlock()
        let url = diskURL(for: key)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    private func diskURL(for key: String) -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("SikaMTV/VisionMasks", isDirectory: true)
            .appendingPathComponent(key).appendingPathExtension("png")
    }

    private func cacheKey(for url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = attributes?[.size] as? NSNumber
        let modified = attributes?[.modificationDate] as? Date
        let identity = "\(url.standardizedFileURL.path)|\(size?.int64Value ?? 0)|\(modified?.timeIntervalSince1970 ?? 0)|vision-mask-v2"
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in identity.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(hash, radix: 16)
    }
}
