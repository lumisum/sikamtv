import AVFoundation
import Foundation

struct BackgroundAudioMixResult {
    let composition: AVMutableComposition
    let audioMix: AVAudioMix
}

enum BackgroundAudioMixer {
    struct LoopClip: Equatable {
        let destinationStart: Double
        let sourceStart: Double
        let duration: Double
        let fadeIn: Double
        let fadeOut: Double
    }

    static func make(
        mainAudioURL: URL,
        backgrounds: [BackgroundMedia],
        projectDuration: Double,
        backgroundAudioEnabled: Bool,
        backgroundVolume: Double,
        transitionDuration: Double,
        loopMainAudio: Bool = false
    ) throws -> BackgroundAudioMixResult {
        let composition = AVMutableComposition()
        var parameters: [AVAudioMixInputParameters] = []
        let mainAsset = AVAsset(url: mainAudioURL)
        guard let mainSource = AVAssetMetadata.tracks(in: mainAsset, mediaType: .audio).first else {
            throw NSError(domain: "SikaMTV.BackgroundAudioMixer", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取主音乐音轨"])
        }
        let loadedDuration = AVAssetMetadata.duration(of: mainAsset)?.seconds ?? projectDuration
        let sourceDuration = loadedDuration.isFinite ? loadedDuration : projectDuration
        if loopMainAudio, sourceDuration > 0, projectDuration > sourceDuration {
            let tracks = (0..<2).compactMap { _ in composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
            guard tracks.count == 2 else { throw NSError(domain: "SikaMTV.BackgroundAudioMixer", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法创建循环 BGM 音轨"]) }
            let trackParameters = tracks.map { AVMutableAudioMixInputParameters(track: $0) }
            for (index, clip) in loopClips(sourceDuration: sourceDuration, projectDuration: projectDuration, transitionDuration: transitionDuration).enumerated() {
                let track = tracks[index % tracks.count]
                let input = trackParameters[index % trackParameters.count]
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: cmTime(clip.duration)), of: mainSource, at: cmTime(clip.destinationStart))
                applyVolumeRamps(input, clip: clip, volume: 1)
            }
            parameters.append(contentsOf: trackParameters)
        } else {
            guard let mainTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw NSError(domain: "SikaMTV.BackgroundAudioMixer", code: 3, userInfo: [NSLocalizedDescriptionKey: "无法创建主音乐音轨"])
            }
            let mainDuration = min(projectDuration, sourceDuration)
            try mainTrack.insertTimeRange(CMTimeRange(start: .zero, duration: cmTime(mainDuration)), of: mainSource, at: .zero)
            let mainParameters = AVMutableAudioMixInputParameters(track: mainTrack)
            mainParameters.setVolume(1, at: .zero)
            parameters.append(mainParameters)
        }

        if backgroundAudioEnabled, projectDuration > 0 {
            let videoBackgrounds = backgrounds.enumerated().filter { $0.element.kind == .video && $0.element.hasAudio }
            if backgrounds.count == 1, let media = videoBackgrounds.first?.element {
                try appendSingleLoopingVideo(
                    media,
                    to: composition,
                    parameters: &parameters,
                    projectDuration: projectDuration,
                    volume: Float(min(1, max(0, backgroundVolume))),
                    transitionDuration: transitionDuration
                )
            } else if !videoBackgrounds.isEmpty {
                try appendBackgroundSegments(
                    backgrounds,
                    to: composition,
                    parameters: &parameters,
                    projectDuration: projectDuration,
                    volume: Float(min(1, max(0, backgroundVolume))),
                    transitionDuration: transitionDuration
                )
            }
        }

        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return BackgroundAudioMixResult(composition: composition, audioMix: mix)
    }

    static func singleVideoLoopClips(videoDuration: Double, projectDuration: Double, transitionDuration: Double) -> [LoopClip] {
        loopClips(sourceDuration: videoDuration, projectDuration: projectDuration, transitionDuration: transitionDuration)
    }

    static func loopClips(sourceDuration: Double, projectDuration: Double, transitionDuration: Double) -> [LoopClip] {
        guard sourceDuration > 0, projectDuration > 0 else { return [] }
        let blend = min(max(0.2, transitionDuration), sourceDuration * 0.25)
        let step = max(0.001, sourceDuration - blend)
        var clips: [LoopClip] = []
        var start = 0.0
        while start < projectDuration - 0.000_001 {
            let length = min(sourceDuration, projectDuration - start)
            clips.append(LoopClip(
                destinationStart: start,
                sourceStart: 0,
                duration: length,
                fadeIn: start > 0 ? min(blend, length) : 0,
                fadeOut: start + length < projectDuration ? min(blend, length) : 0
            ))
            start += step
        }
        return clips
    }

    private static func appendSingleLoopingVideo(
        _ media: BackgroundMedia,
        to composition: AVMutableComposition,
        parameters: inout [AVAudioMixInputParameters],
        projectDuration: Double,
        volume: Float,
        transitionDuration: Double
    ) throws {
        let asset = AVAsset(url: media.url)
        guard let source = AVAssetMetadata.tracks(in: asset, mediaType: .audio).first else { return }
        let tracks = (0..<2).compactMap { _ in composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
        guard tracks.count == 2 else { return }
        let trackParameters = tracks.map { AVMutableAudioMixInputParameters(track: $0) }
        let clips = singleVideoLoopClips(videoDuration: media.duration, projectDuration: projectDuration, transitionDuration: transitionDuration)
        for (index, clip) in clips.enumerated() {
            let track = tracks[index % tracks.count]
            let input = trackParameters[index % tracks.count]
            try track.insertTimeRange(
                CMTimeRange(start: cmTime(clip.sourceStart), duration: cmTime(clip.duration)),
                of: source,
                at: cmTime(clip.destinationStart)
            )
            applyVolumeRamps(input, clip: clip, volume: volume)
        }
        parameters.append(contentsOf: trackParameters)
    }

    private static func appendBackgroundSegments(
        _ backgrounds: [BackgroundMedia],
        to composition: AVMutableComposition,
        parameters: inout [AVAudioMixInputParameters],
        projectDuration: Double,
        volume: Float,
        transitionDuration: Double
    ) throws {
        let tracks = (0..<2).compactMap { _ in composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
        guard tracks.count == 2 else { return }
        let trackParameters = tracks.map { AVMutableAudioMixInputParameters(track: $0) }
        let segmentDuration = projectDuration / Double(backgrounds.count)
        var clipIndex = 0

        for (index, media) in backgrounds.enumerated() where media.kind == .video && media.hasAudio && media.duration > 0 {
            let asset = AVAsset(url: media.url)
            guard let source = AVAssetMetadata.tracks(in: asset, mediaType: .audio).first else { continue }
            let segmentStart = Double(index) * segmentDuration
            let segmentEnd = min(projectDuration, segmentStart + segmentDuration)
            var destination = segmentStart
            while destination < segmentEnd - 0.000_001 {
                let length = min(media.duration, segmentEnd - destination)
                let track = tracks[clipIndex % tracks.count]
                let input = trackParameters[clipIndex % tracks.count]
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: cmTime(length)), of: source, at: cmTime(destination))
                let edgeFade = min(max(0.05, transitionDuration * 0.25), length * 0.25)
                applyVolumeRamps(
                    input,
                    clip: LoopClip(destinationStart: destination, sourceStart: 0, duration: length, fadeIn: edgeFade, fadeOut: edgeFade),
                    volume: volume
                )
                destination += length
                clipIndex += 1
            }
        }
        parameters.append(contentsOf: trackParameters)
    }

    private static func applyVolumeRamps(_ parameters: AVMutableAudioMixInputParameters, clip: LoopClip, volume: Float) {
        let start = cmTime(clip.destinationStart)
        let end = cmTime(clip.destinationStart + clip.duration)
        if clip.fadeIn > 0 {
            parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: volume, timeRange: CMTimeRange(start: start, duration: cmTime(clip.fadeIn)))
        } else {
            parameters.setVolume(volume, at: start)
        }
        if clip.fadeOut > 0 {
            parameters.setVolumeRamp(fromStartVolume: volume, toEndVolume: 0, timeRange: CMTimeRange(start: cmTime(clip.destinationStart + clip.duration - clip.fadeOut), duration: cmTime(clip.fadeOut)))
        } else {
            parameters.setVolume(volume, at: end)
        }
    }

    private static func cmTime(_ seconds: Double) -> CMTime {
        CMTime(seconds: max(0, seconds), preferredTimescale: 44_100)
    }
}
