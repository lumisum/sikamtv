import AVFoundation
import AppKit
import CoreVideo
import Foundation

final class ExportCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

final class VideoExporter: @unchecked Sendable {
    struct ExportProgress {
        let fraction: Double
        let current: Double
        let duration: Double
        let status: String
    }

    enum ExportError: LocalizedError {
        case cannotCreateWriter
        case cannotCreatePixelBuffer
        case cannotReadAudio
        case failedToWrite
        case cancelled

        var errorDescription: String? {
            switch self {
            case .cannotCreateWriter: return "无法创建 MP4 编码器"
            case .cannotCreatePixelBuffer: return "无法创建视频帧"
            case .cannotReadAudio: return "无法读取音频"
            case .failedToWrite: return "视频写入失败"
            case .cancelled: return "已停止生成"
            }
        }
    }

    func export(to url: URL, backgrounds: [BackgroundMedia], audioURL: URL, lyrics: [LRCLine], analysis: AudioAnalysis, settings: RenderSettings, fontName: String, backgroundAudioEnabled: Bool = false, backgroundAudioVolume: Double = 0.25, cancellationToken: ExportCancellationToken = ExportCancellationToken(), progress: @escaping (ExportProgress) -> Void) throws {
        let duration = analysis.duration
        let size = settings.aspectRatio.size1080
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { throw ExportError.cannotCreateWriter }
        var completed = false
        defer {
            if !completed {
                writer.cancelWriting()
            }
        }

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 12_000_000,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 30
            ]
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        writer.add(videoInput)

        let mixedAudio: BackgroundAudioMixResult
        do {
            mixedAudio = try BackgroundAudioMixer.make(
                mainAudioURL: audioURL,
                backgrounds: backgrounds,
                projectDuration: duration,
                backgroundAudioEnabled: backgroundAudioEnabled,
                backgroundVolume: backgroundAudioVolume,
                transitionDuration: settings.backgroundTransitionDuration
            )
        } catch {
            throw ExportError.cannotReadAudio
        }
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 44_100,
            AVEncoderBitRateKey: 192_000
        ])
        audioInput.expectsMediaDataInRealTime = false
        writer.add(audioInput)
        let reader = try AVAssetReader(asset: mixedAudio.composition)
        let audioTracks = AVAssetMetadata.tracks(in: mixedAudio.composition, mediaType: .audio)
        guard !audioTracks.isEmpty else { throw ExportError.cannotReadAudio }
        let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMBitDepthKey: 16
        ])
        audioOutput.audioMix = mixedAudio.audioMix
        audioOutput.alwaysCopiesSampleData = false
        reader.add(audioOutput)
        guard writer.startWriting() else { throw writer.error ?? ExportError.failedToWrite }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else { throw reader.error ?? ExportError.cannotReadAudio }
        defer {
            if reader.status == .reading { reader.cancelReading() }
        }

        try checkCancellation(cancellationToken)
        let reporter = ExportProgressReporter(duration: duration, handler: progress)
        reporter.send(fraction: 0.005, current: 0, status: "正在准备编码")

        let session = ExportSession(
            writer: writer,
            videoInput: videoInput,
            audioInput: audioInput,
            adaptor: adaptor,
            reader: reader,
            audioOutput: audioOutput,
            videoSource: ExportVideoSource(
                backgrounds: backgrounds,
                lyrics: lyrics,
                analysis: analysis,
                settings: settings,
                fontName: fontName,
                duration: duration,
                size: size
            ),
            reporter: reporter,
            cancellationToken: cancellationToken
        )
        session.start()
        do {
            try session.waitUntilTracksFinish(cancellationToken: cancellationToken)
        } catch {
            session.stopTracks()
            throw error
        }

        try checkCancellation(cancellationToken)
        if let error = session.encodingError { throw error }
        reporter.send(fraction: 0.99, current: duration, status: "正在完成文件")
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        while semaphore.wait(timeout: .now() + 0.1) == .timedOut {
            try checkCancellation(cancellationToken)
        }
        guard writer.status == .completed else { throw writer.error ?? ExportError.failedToWrite }
        completed = true
        reporter.send(fraction: 1, current: duration, status: "生成完成")
    }

    private func checkCancellation(_ token: ExportCancellationToken) throws {
        if token.isCancelled || Task.isCancelled { throw ExportError.cancelled }
    }
}

/// Pulls audio and video on independent serial queues so AVAssetWriter can keep
/// its interleaving window moving. Sleeping on one input is what previously
/// deadlocked real-length exports after the first progress update.
private final class ExportSession: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let reader: AVAssetReader
    private let audioOutput: AVAssetReaderAudioMixOutput
    private let videoSource: ExportVideoSource
    private let reporter: ExportProgressReporter
    private let cancellationToken: ExportCancellationToken
    private let coordinator = ExportCoordinator()
    private let group = DispatchGroup()
    private let videoQueue = DispatchQueue(label: "SikaMTV.Export.Video", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "SikaMTV.Export.Audio", qos: .userInitiated)

    var encodingError: Error? { coordinator.error }

    init(
        writer: AVAssetWriter,
        videoInput: AVAssetWriterInput,
        audioInput: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        reader: AVAssetReader,
        audioOutput: AVAssetReaderAudioMixOutput,
        videoSource: ExportVideoSource,
        reporter: ExportProgressReporter,
        cancellationToken: ExportCancellationToken
    ) {
        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.adaptor = adaptor
        self.reader = reader
        self.audioOutput = audioOutput
        self.videoSource = videoSource
        self.reporter = reporter
        self.cancellationToken = cancellationToken
    }

    func start() {
        group.enter()
        group.enter()
        requestVideo()
        requestAudio()
    }

    func stopTracks() {
        coordinator.cancel()
        videoQueue.async { [weak self] in self?.finishVideo() }
        audioQueue.async { [weak self] in self?.finishAudio() }
        _ = group.wait(timeout: .now() + 8)
    }

    func waitUntilTracksFinish(cancellationToken: ExportCancellationToken) throws {
        while true {
            let finished = group.wait(timeout: .now() + 0.1) == .success
            if cancellationToken.isCancelled || Task.isCancelled {
                coordinator.cancel()
                throw VideoExporter.ExportError.cancelled
            }
            if let error = coordinator.error {
                throw error
            }
            if finished { return }
        }
    }

    private func requestVideo() {
        videoInput.requestMediaDataWhenReady(on: videoQueue) { [weak self] in
            guard let self else { return }
            if self.shouldStopTracks {
                self.finishVideo()
                return
            }
            while self.videoInput.isReadyForMoreMediaData {
                if self.shouldStopTracks {
                    self.finishVideo()
                    return
                }
                if self.videoSource.isComplete {
                    self.finishVideo()
                    return
                }
                do {
                    try self.videoSource.appendNextFrame(using: self.adaptor, writer: self.writer)
                    self.reporter.encodedVideo(at: self.videoSource.encodedTime, totalFrames: self.videoSource.frameCount)
                } catch {
                    self.coordinator.fail(error)
                    self.finishVideo()
                    return
                }
            }
        }
    }

    private func requestAudio() {
        audioInput.requestMediaDataWhenReady(on: audioQueue) { [weak self] in
            guard let self else { return }
            if self.shouldStopTracks {
                self.finishAudio()
                return
            }
            while self.audioInput.isReadyForMoreMediaData {
                if self.shouldStopTracks {
                    self.finishAudio()
                    return
                }
                if let sample = self.audioOutput.copyNextSampleBuffer() {
                    guard self.audioInput.append(sample) else {
                        self.coordinator.fail(self.writer.error ?? VideoExporter.ExportError.failedToWrite)
                        self.finishAudio()
                        return
                    }
                    continue
                }
                if self.reader.status == .failed {
                    self.coordinator.fail(self.reader.error ?? VideoExporter.ExportError.cannotReadAudio)
                }
                self.finishAudio()
                return
            }
        }
    }

    private var shouldStopTracks: Bool {
        coordinator.shouldStop || cancellationToken.isCancelled || Task.isCancelled
    }

    private func finishVideo() {
        guard coordinator.stopVideo() else { return }
        videoInput.markAsFinished()
        group.leave()
    }

    private func finishAudio() {
        guard coordinator.stopAudio() else { return }
        audioInput.markAsFinished()
        group.leave()
    }
}

private final class ExportCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var videoStopped = false
    private var audioStopped = false
    private var cancelled = false
    private var failure: Error?

    var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled || failure != nil
    }

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func fail(_ error: Error) {
        lock.lock()
        if failure == nil { failure = error }
        lock.unlock()
    }

    func stopVideo() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if videoStopped { return false }
        videoStopped = true
        return true
    }

    func stopAudio() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if audioStopped { return false }
        audioStopped = true
        return true
    }
}

private final class ExportProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private let duration: Double
    private let handler: (VideoExporter.ExportProgress) -> Void
    private var lastPublishedFrame = -1

    init(duration: Double, handler: @escaping (VideoExporter.ExportProgress) -> Void) {
        self.duration = duration
        self.handler = handler
    }

    func encodedVideo(at time: Double, totalFrames: Int) {
        let frame = max(0, Int((time * 30).rounded(.down)))
        lock.lock()
        let shouldPublish = frame == 0 || frame == totalFrames - 1 || frame - lastPublishedFrame >= 2
        if shouldPublish { lastPublishedFrame = frame }
        lock.unlock()
        guard shouldPublish else { return }
        let fraction = 0.01 + Double(frame + 1) / Double(max(totalFrames, 1)) * 0.94
        send(fraction: fraction, current: time, status: "正在编码音视频")
    }

    func send(fraction: Double, current: Double, status: String) {
        let progress = VideoExporter.ExportProgress(
            fraction: min(1, max(0, fraction)),
            current: current,
            duration: duration,
            status: status
        )
        lock.lock()
        handler(progress)
        lock.unlock()
    }
}

private final class ExportVideoSource: @unchecked Sendable {
    private let render = RenderEngine()
    private var staticImages: [URL: CGImage] = [:]
    private let videoDecoders = VideoFrameDecoderPool()
    private let backgrounds: [BackgroundMedia]
    private let lyrics: [LRCLine]
    private let analysis: AudioAnalysis
    private let settings: RenderSettings
    private let fontName: String
    private let duration: Double
    private let size: CGSize
    private let fps = 30.0
    private var nextFrame = 0

    let frameCount: Int

    var isComplete: Bool { nextFrame >= frameCount }
    var encodedTime: Double { Double(max(0, nextFrame - 1)) / fps }

    init(
        backgrounds: [BackgroundMedia],
        lyrics: [LRCLine],
        analysis: AudioAnalysis,
        settings: RenderSettings,
        fontName: String,
        duration: Double,
        size: CGSize
    ) {
        self.backgrounds = backgrounds
        self.lyrics = lyrics
        self.analysis = analysis
        self.settings = settings
        self.fontName = fontName
        self.duration = duration
        self.size = size
        self.frameCount = Int(ceil(max(0, duration) * 30))
    }

    func appendNextFrame(using adaptor: AVAssetWriterInputPixelBufferAdaptor, writer: AVAssetWriter) throws {
        let frame = nextFrame
        try autoreleasepool {
            let time = Double(frame) / fps
            let timeline = BackgroundTimeline.state(
                at: time,
                duration: duration,
                itemCount: backgrounds.count,
                transition: settings.backgroundTransition,
                transitionDuration: settings.backgroundTransitionDuration,
                singleVideoDuration: backgrounds.count == 1 && backgrounds[0].kind == .video ? backgrounds[0].duration : nil
            )
            let currentMedia = timeline.map { backgrounds[$0.currentIndex] }
            let nextMedia = timeline?.nextIndex.map { backgrounds[$0] }
            let frameImage = image(for: currentMedia, at: timeline?.currentLocalTime ?? time, role: 0)
            let nextFrameImage = image(for: nextMedia, at: timeline?.nextLocalTime ?? 0, role: 1)
            guard let pixelBuffer = makePixelBuffer(pool: adaptor.pixelBufferPool) else {
                throw VideoExporter.ExportError.cannotCreatePixelBuffer
            }
            let rendered = render.render(
                into: pixelBuffer,
                size: size,
                time: time,
                settings: settings,
                background: frameImage,
                backgroundDuration: currentMedia?.duration ?? 0,
                backgroundIdentifier: currentMedia?.kind == .image ? currentMedia?.url.path : nil,
                nextBackground: nextFrameImage,
                nextBackgroundDuration: nextMedia?.duration ?? 0,
                nextBackgroundIdentifier: nextMedia?.kind == .image ? nextMedia?.url.path : nil,
                backgroundTimeline: timeline,
                lyrics: lyrics,
                analysis: analysis,
                fontName: fontName
            )
            guard rendered else { throw VideoExporter.ExportError.cannotCreatePixelBuffer }
            let presentation = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
            guard adaptor.append(pixelBuffer, withPresentationTime: presentation) else {
                throw writer.error ?? VideoExporter.ExportError.failedToWrite
            }
        }
        nextFrame += 1
    }

    private func image(for media: BackgroundMedia?, at localTime: Double, role: Int) -> CGImage? {
        guard let media else { return nil }
        if media.kind == .image {
            if let cached = staticImages[media.url] { return cached }
            let loaded = NSImage(contentsOf: media.url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            if let loaded { staticImages[media.url] = loaded }
            return loaded
        }
        return videoDecoders.image(for: media.url, at: media.playbackTime(for: localTime), role: role)
    }

    private func makePixelBuffer(pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        if let pool {
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess else { return nil }
        } else {
            let attrs = [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:]
            ] as CFDictionary
            guard CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, attrs, &pixelBuffer) == kCVReturnSuccess else { return nil }
        }
        return pixelBuffer
    }
}
