import AVFoundation
import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class MediaManager {
    static let shared = MediaManager()

    func chooseAssetURLs() -> [URL] {
        let panel = NSOpenPanel()
        var types: [UTType] = [.jpeg, .png, .heic, .mpeg4Movie, .quickTimeMovie, .audio, .plainText]
        if let lrc = UTType(filenameExtension: "lrc") { types.append(lrc) }
        if let srt = UTType(filenameExtension: "srt") { types.append(srt) }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = true
        panel.message = "选择图片、视频、音频或 LRC / SRT 字幕，可同时选择多个文件"
        panel.prompt = "导入资源"
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }

    func chooseBackgroundURLs() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .heic, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = true
        panel.message = "选择一张或多张背景图片 / 视频"
        panel.prompt = "选择背景"
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }

    nonisolated static func backgroundMedia(for url: URL) -> BackgroundMedia? {
        let supportedImages = ["jpg", "jpeg", "png", "heic"]
        let isVideo = ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
        guard isVideo || supportedImages.contains(url.pathExtension.lowercased()) else { return nil }
        let asset = AVAsset(url: url)
        let loadedDuration = isVideo ? AVAssetMetadata.duration(of: asset)?.seconds ?? 0 : 0
        let duration = loadedDuration.isFinite ? loadedDuration : 0
        let hasAudio = isVideo && !AVAssetMetadata.tracks(in: asset, mediaType: .audio).isEmpty
        return BackgroundMedia(url: url, kind: isVideo ? .video : .image, duration: duration, hasAudio: hasAudio)
    }

    func chooseAudio() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.message = "选择 WAV、MP3、M4A 等音频文件"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func chooseLyrics() -> URL? {
        let panel = NSOpenPanel()
        var subtitleTypes: [UTType] = [.plainText]
        if let lrcType = UTType(filenameExtension: "lrc") { subtitleTypes.append(lrcType) }
        if let srtType = UTType(filenameExtension: "srt") { subtitleTypes.append(srtType) }
        panel.allowedContentTypes = subtitleTypes
        panel.allowsMultipleSelection = false
        panel.message = "选择 LRC 或 SRT 字幕文件"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
