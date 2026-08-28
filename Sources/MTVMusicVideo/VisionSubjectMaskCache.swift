import CoreImage
import Foundation
import ImageIO
import Vision

/// Builds a reusable protection mask for each imported still image. Vision runs
/// once during import (or lazily on the first render), never in the frame loop.
final class VisionSubjectMaskCache: @unchecked Sendable {
    static let shared = VisionSubjectMaskCache()

    private let lock = NSLock()
    private var memory: [String: CGImage] = [:]
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

    private func analyze(_ image: CGImage, orientation: CGImagePropertyOrientation) -> CGImage? {
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        let faces = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation)
        try? handler.perform([saliency, faces])
        let saliencyImage = saliency.results?.first.flatMap { saliencyCGImage(from: $0.pixelBuffer) }
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
        let identity = "\(url.standardizedFileURL.path)|\(size?.int64Value ?? 0)|\(modified?.timeIntervalSince1970 ?? 0)|vision-mask-v1"
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in identity.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(hash, radix: 16)
    }
}
