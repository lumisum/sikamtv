import AVFoundation
import AppKit
import Foundation

struct PreviewSnapshot: @unchecked Sendable {
    let size: CGSize
    let time: Double
    let settings: RenderSettings
    let backgrounds: [BackgroundMedia]
    let projectDuration: Double
    let lyrics: [LRCLine]
    let analysis: AudioAnalysis?
    let fontName: String
}

private struct PreviewResult: @unchecked Sendable {
    let image: CGImage?
    let milliseconds: Double
}

/// Serial, latest-frame-wins renderer. UI state is snapshotted on the main actor,
/// while media decoding, Core Image and bitmap drawing stay off the main thread.
final class PreviewRenderer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.sikamtv.preview-renderer", qos: .userInteractive)
    private let lock = NSLock()
    private var requestedGeneration = 0
    private let engine = RenderEngine()
    private var imageCache: [URL: CGImage] = [:]
    private var videoGenerators: [URL: AVAssetImageGenerator] = [:]

    func request(_ snapshot: PreviewSnapshot, completion: @escaping @MainActor (CGImage?, Double) -> Void) {
        lock.lock()
        requestedGeneration += 1
        let generation = requestedGeneration
        lock.unlock()

        queue.async { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            let start = CFAbsoluteTimeGetCurrent()
            let timeline = BackgroundTimeline.state(
                at: snapshot.time,
                duration: snapshot.projectDuration,
                itemCount: snapshot.backgrounds.count,
                transition: snapshot.settings.backgroundTransition,
                transitionDuration: snapshot.settings.backgroundTransitionDuration
            )
            let currentMedia = timeline.map { snapshot.backgrounds[$0.currentIndex] }
            let nextMedia = timeline?.nextIndex.map { snapshot.backgrounds[$0] }
            let backgroundImage = self.backgroundImage(for: currentMedia, at: timeline?.currentLocalTime ?? snapshot.time)
            let nextBackgroundImage = self.backgroundImage(for: nextMedia, at: timeline?.nextLocalTime ?? 0)
            guard self.isCurrent(generation) else { return }
            let image = self.engine.render(
                size: snapshot.size,
                time: snapshot.time,
                settings: snapshot.settings,
                background: backgroundImage,
                backgroundDuration: currentMedia?.duration ?? 0,
                backgroundIdentifier: currentMedia?.kind == .image ? currentMedia?.url.path : nil,
                nextBackground: nextBackgroundImage,
                nextBackgroundDuration: nextMedia?.duration ?? 0,
                nextBackgroundIdentifier: nextMedia?.kind == .image ? nextMedia?.url.path : nil,
                backgroundTimeline: timeline,
                lyrics: snapshot.lyrics,
                analysis: snapshot.analysis,
                fontName: snapshot.fontName
            )
            let result = PreviewResult(image: image, milliseconds: (CFAbsoluteTimeGetCurrent() - start) * 1_000)
            guard self.isCurrent(generation) else { return }
            Task { @MainActor in completion(result.image, result.milliseconds) }
        }
    }

    func invalidateMediaCaches() {
        queue.async { [weak self] in
            self?.imageCache.removeAll()
            self?.videoGenerators.removeAll()
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == requestedGeneration
    }

    private func backgroundImage(for media: BackgroundMedia?, at time: Double) -> CGImage? {
        guard let media else { return nil }
        if media.kind == .image {
            if let cached = imageCache[media.url] { return cached }
            let image = NSImage(contentsOf: media.url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            if let image { imageCache[media.url] = image }
            return image
        }
        let generator: AVAssetImageGenerator
        if let cached = videoGenerators[media.url] { generator = cached }
        else {
            generator = AVAssetImageGenerator(asset: AVAsset(url: media.url))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
            generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
            videoGenerators[media.url] = generator
        }
        let loopTime = media.playbackTime(for: time)
        return try? generator.copyCGImage(at: CMTime(seconds: loopTime, preferredTimescale: 600), actualTime: nil)
    }
}
