import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import Metal

/// Sequential video decoder optimized for timeline playback. AVAssetImageGenerator
/// performs a random seek for each requested frame; this reader keeps the hardware
/// decoder warm and only resets after a real seek, loop, or background switch.
final class VideoFrameDecoder {
    private let asset: AVAsset
    private let track: AVAssetTrack
    private let duration: Double
    private let ciContext: CIContext
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var lastRequestTime: Double = -.greatestFiniteMagnitude
    private var lastImage: CGImage?

    init?(url: URL, ciContext: CIContext) {
        let asset = AVAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { return nil }
        self.asset = asset
        self.track = track
        self.duration = asset.duration.seconds.isFinite ? asset.duration.seconds : 0
        self.ciContext = ciContext
    }

    func image(at requestedTime: Double) -> CGImage? {
        let target = min(max(0, requestedTime), max(0, duration - 0.000_001))
        let movedBackward = target + 0.04 < lastRequestTime
        let jumpedForward = target - lastRequestTime > 0.75
        if reader == nil || movedBackward || jumpedForward {
            reset(startingAt: target)
        }
        lastRequestTime = target

        while let output, let sample = output.copyNextSampleBuffer() {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let image = makeImage(from: pixelBuffer)
            if let image { lastImage = image }
            if !timestamp.isFinite || timestamp >= target - (1.0 / 60.0) { return image ?? lastImage }
        }
        return lastImage
    }

    func invalidate() {
        reader?.cancelReading()
        reader = nil
        output = nil
        lastImage = nil
        lastRequestTime = -.greatestFiniteMagnitude
    }

    private func reset(startingAt time: Double) {
        reader?.cancelReading()
        lastImage = nil
        guard let reader = try? AVAssetReader(asset: asset) else { return }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return }
        reader.add(output)
        if duration > 0 {
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: time, preferredTimescale: 600),
                duration: CMTime(seconds: max(0.001, duration - time), preferredTimescale: 600)
            )
        }
        guard reader.startReading() else { return }
        self.reader = reader
        self.output = output
    }

    private func makeImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let transformed = source.transformed(by: track.preferredTransform)
        let extent = transformed.extent.standardized
        let normalized = transformed.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        return ciContext.createCGImage(normalized, from: normalized.extent)
    }
}

final class VideoFrameDecoderPool {
    private struct Key: Hashable {
        let url: URL
        let role: Int
    }

    private let ciContext: CIContext = {
        let options: [CIContextOption: Any] = [.useSoftwareRenderer: false, .cacheIntermediates: false]
        if let device = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: device, options: options) }
        return CIContext(options: options)
    }()
    private var decoders: [Key: VideoFrameDecoder] = [:]

    func image(for url: URL, at time: Double, role: Int) -> CGImage? {
        let key = Key(url: url, role: role)
        if let decoder = decoders[key] { return decoder.image(at: time) }
        guard let decoder = VideoFrameDecoder(url: url, ciContext: ciContext) else { return nil }
        decoders[key] = decoder
        return decoder.image(at: time)
    }

    func invalidate() {
        decoders.values.forEach { $0.invalidate() }
        decoders.removeAll(keepingCapacity: true)
    }
}
