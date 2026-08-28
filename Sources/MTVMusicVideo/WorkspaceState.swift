import AVFoundation
import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class WorkspaceState: ObservableObject {
    let previewUpdates = PassthroughSubject<Void, Never>()

    @Published var backgrounds: [BackgroundMedia] = [] {
        didSet { previewRenderer.invalidateMediaCaches(); previewUpdates.send(()); schedulePlaybackMixRefresh() }
    }
    @Published private(set) var backgroundLibrary: [BackgroundMedia] = []
    @Published private(set) var audioLibrary: [URL] = []
    @Published private(set) var lyricsLibrary: [URL] = []
    @Published var audioURL: URL?
    @Published var lyricsURL: URL?
    @Published var lyrics: [LRCLine] = [] { didSet { previewUpdates.send(()) } }
    @Published var settings: RenderSettings {
        didSet {
            persistSettings()
            previewUpdates.send(())
            if oldValue.backgroundTransitionDuration != settings.backgroundTransitionDuration { schedulePlaybackMixRefresh() }
        }
    }
    @Published var backgroundAudioEnabled: Bool {
        didSet {
            UserDefaults.standard.set(backgroundAudioEnabled, forKey: "SikaMTV.BackgroundAudioEnabled")
            schedulePlaybackMixRefresh()
        }
    }
    @Published var backgroundAudioVolume: Double {
        didSet {
            UserDefaults.standard.set(backgroundAudioVolume, forKey: "SikaMTV.BackgroundAudioVolume")
            schedulePlaybackMixRefresh()
        }
    }
    @Published var selectedFont: FontOption? { didSet { previewUpdates.send(()) } }
    @Published var audioAnalysis: AudioAnalysis? { didSet { previewUpdates.send(()) } }
    @Published var currentTime: Double = 0 { didSet { previewUpdates.send(()) } }
    @Published var isPlaying = false
    @Published var isAnalyzingAudio = false
    @Published var isLoadingBackgrounds = false
    @Published var audioAnalysisProgress: Double = 0
    @Published var audioAnalysisStatus = ""
    @Published private(set) var audioDuration: Double = 0
    @Published private(set) var previewRenderMilliseconds: Double = 0
    @Published var isExporting = false
    @Published var exportFraction: Double = 0
    @Published var exportMessage = ""
    @Published var exportCurrentTime: Double = 0
    @Published var exportTotalDuration: Double = 0
    @Published var alertMessage: String?

    let fontManager = FontManager()
    private let exporter = VideoExporter()
    private let previewRenderer = PreviewRenderer()
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var playbackEndObserver: NSObjectProtocol?
    private var audioAnalysisTask: Task<AudioAnalysis, Error>?
    private var mixRefreshTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var exportCancellationToken: ExportCancellationToken?

    init() {
        backgroundAudioEnabled = UserDefaults.standard.bool(forKey: "SikaMTV.BackgroundAudioEnabled")
        backgroundAudioVolume = UserDefaults.standard.object(forKey: "SikaMTV.BackgroundAudioVolume") as? Double ?? 0.25
        if let data = UserDefaults.standard.data(forKey: "SikaMTV.RenderSettings"),
           var restored = try? JSONDecoder().decode(RenderSettings.self, from: data) {
            if restored.fontPostScriptName == "PingFangSC-Regular" {
                restored.fontPostScriptName = FontManager.defaultPostScriptName
            }
            settings = restored
        } else {
            settings = RenderSettings()
        }
        selectedFont = fontManager.fonts.first(where: { $0.postScriptName == settings.fontPostScriptName }) ?? fontManager.fonts.first
    }

    var duration: Double { audioAnalysis?.duration ?? audioDuration }
    var hasRequiredMedia: Bool { !backgrounds.isEmpty && audioURL != nil && !lyrics.isEmpty && audioAnalysis != nil }
    var backgroundSummary: String? {
        guard !backgrounds.isEmpty else { return nil }
        if backgrounds.count == 1 { return backgrounds[0].url.lastPathComponent }
        let imageCount = backgrounds.filter { $0.kind == .image }.count
        let videoCount = backgrounds.count - imageCount
        let parts = [imageCount > 0 ? "\(imageCount)图" : nil, videoCount > 0 ? "\(videoCount)视频" : nil].compactMap { $0 }
        return "\(backgrounds.count) 个背景 · \(parts.joined(separator: " "))"
    }
    var backgroundSegmentDuration: Double? {
        guard backgrounds.count > 1, duration > 0 else { return nil }
        return duration / Double(backgrounds.count)
    }
    var hasBackgroundAudio: Bool { backgrounds.contains { $0.kind == .video && $0.hasAudio } }

    func importBackground() {
        let urls = MediaManager.shared.chooseBackgroundURLs()
        guard !urls.isEmpty else { return }
        loadBackgrounds(from: urls)
    }

    func importAssets() {
        let urls = MediaManager.shared.chooseAssetURLs()
        guard !urls.isEmpty else { return }
        let backgroundURLs = urls.filter { ["jpg", "jpeg", "png", "heic", "mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) }
        if !backgroundURLs.isEmpty { loadBackgrounds(from: backgroundURLs) }
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if ["wav", "mp3", "m4a", "aac", "aiff", "flac"].contains(ext) {
                addAudioToLibrary(url)
            } else if ["lrc", "srt"].contains(ext) {
                addLyricsToLibrary(url)
            }
        }
    }

    func importAudio() {
        guard let url = MediaManager.shared.chooseAudio() else { return }
        addAudioToLibrary(url)
    }

    func importAudio(url: URL) {
        addAudioToLibrary(url)
    }

    func activateAudio(_ url: URL) {
        addAudioToLibrary(url)
        loadAudio(url: url)
    }

    private func loadAudio(url: URL) {
        audioAnalysisTask?.cancel()
        audioURL = url
        audioAnalysis = nil
        audioDuration = audioFileDuration(for: url)
        audioAnalysisProgress = 0
        audioAnalysisStatus = "准备分析"
        isAnalyzingAudio = true
        currentTime = 0
        lyricsURL = nil
        lyrics = []
        replacePlayer(with: url, at: 0, resume: false)
        if let matchingSubtitle = matchingSubtitle(for: url) { addLyricsToLibrary(matchingSubtitle) }

        let progressHandler: @Sendable (Double) -> Void = { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.audioURL == url else { return }
                self.audioAnalysisProgress = progress
                self.audioAnalysisStatus = "正在提取节拍与频谱"
            }
        }
        let task = Task.detached(priority: .userInitiated) {
            if let cached = AudioAnalysisCache.shared.load(for: url) {
                progressHandler(1)
                return cached
            }
            let result = try AudioAnalyzer().analyze(url: url, progress: progressHandler)
            AudioAnalysisCache.shared.save(result, for: url)
            return result
        }
        audioAnalysisTask = task
        Task { @MainActor [weak self] in
            do {
                let result = try await task.value
                guard let self, self.audioURL == url else { return }
                self.audioAnalysis = result
                self.isAnalyzingAudio = false
                self.audioAnalysisProgress = 1
                self.audioAnalysisStatus = "分析完成"
            } catch is CancellationError {
                // A newer audio import superseded this task.
            } catch {
                guard let self, self.audioURL == url else { return }
                self.isAnalyzingAudio = false
                self.audioAnalysisStatus = "分析失败"
                self.alertMessage = "无法分析音频：\(error.localizedDescription)"
            }
        }
    }

    func cancelAudioAnalysis() {
        audioAnalysisTask?.cancel()
        audioAnalysisTask = nil
        isAnalyzingAudio = false
        audioAnalysisProgress = 0
        audioAnalysisStatus = "已取消"
    }

    func importLyrics() {
        guard let url = MediaManager.shared.chooseLyrics() else { return }
        addLyricsToLibrary(url)
    }

    func importLyrics(url: URL) { addLyricsToLibrary(url) }

    func activateLyrics(_ url: URL) {
        addLyricsToLibrary(url)
        loadLyrics(url: url)
    }

    func handleDropped(url: URL) {
        let ext = url.pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "heic", "mp4", "mov", "m4v"].contains(ext) {
            loadBackgrounds(from: [url])
        } else if ["wav", "mp3", "m4a", "aac", "aiff", "flac"].contains(ext) {
            addAudioToLibrary(url)
        } else if ["lrc", "srt"].contains(ext) {
            addLyricsToLibrary(url)
        }
    }

    func activateAsset(url: URL) {
        let ext = url.pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "heic", "mp4", "mov", "m4v"].contains(ext) {
            if let media = backgroundLibrary.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                activateBackground(media)
            } else {
                loadBackgrounds(from: [url]) { [weak self] in
                    guard let media = $0.first else { return }
                    self?.activateBackground(media)
                }
            }
        } else if ["wav", "mp3", "m4a", "aac", "aiff", "flac"].contains(ext) {
            activateAudio(url)
        } else if ["lrc", "srt"].contains(ext) {
            activateLyrics(url)
        }
    }

    func activateBackground(_ media: BackgroundMedia) {
        guard !backgrounds.contains(where: { $0.url.standardizedFileURL == media.url.standardizedFileURL }) else { return }
        if !backgroundLibrary.contains(where: { $0.url.standardizedFileURL == media.url.standardizedFileURL }) {
            backgroundLibrary.append(media)
        }
        backgrounds.append(media)
    }

    func clearBackgrounds() { backgrounds.removeAll() }
    func removeBackground(_ media: BackgroundMedia) { backgrounds.removeAll { $0.url.standardizedFileURL == media.url.standardizedFileURL } }
    func removeBackgroundFromLibrary(_ media: BackgroundMedia) {
        removeBackground(media)
        backgroundLibrary.removeAll { $0.url.standardizedFileURL == media.url.standardizedFileURL }
    }

    func clearAudio() {
        audioAnalysisTask?.cancel()
        audioAnalysisTask = nil
        stopPlayer()
        audioURL = nil
        audioAnalysis = nil
        audioDuration = 0
        currentTime = 0
        audioAnalysisProgress = 0
        audioAnalysisStatus = ""
    }

    func removeAudioFromLibrary(_ url: URL) {
        audioLibrary.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        if audioURL?.standardizedFileURL == url.standardizedFileURL { clearAudio() }
    }

    func clearLyrics() {
        lyricsURL = nil
        lyrics = []
    }

    func removeLyricsFromLibrary(_ url: URL) {
        lyricsLibrary.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        if lyricsURL?.standardizedFileURL == url.standardizedFileURL { clearLyrics() }
    }

    func importFont() {
        if let font = fontManager.importFont() {
            selectedFont = font
            settings.fontPostScriptName = font.postScriptName
        }
    }

    private func loadBackgrounds(from urls: [URL], completion: (([BackgroundMedia]) -> Void)? = nil) {
        isLoadingBackgrounds = true
        Task { @MainActor [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) {
                urls.compactMap(MediaManager.backgroundMedia(for:))
            }.value
            guard let self else { return }
            let existing = Set(self.backgroundLibrary.map { $0.url.standardizedFileURL })
            self.backgroundLibrary.append(contentsOf: loaded.filter { !existing.contains($0.url.standardizedFileURL) })
            self.isLoadingBackgrounds = false
            if loaded.isEmpty { self.alertMessage = "没有读取到可用的背景图片或视频" }
            completion?(loaded)
        }
    }

    private func addAudioToLibrary(_ url: URL) {
        guard !audioLibrary.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) else { return }
        audioLibrary.append(url)
    }

    private func addLyricsToLibrary(_ url: URL) {
        guard !lyricsLibrary.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) else { return }
        lyricsLibrary.append(url)
    }

    func applyTemplate(_ template: VisualTemplate) {
        var updated = settings
        updated.template = template
        updated.visualizer = template.defaultVisualizer
        switch template {
        case .zen:
            updated.blur = 22; updated.darkness = 0.30; updated.saturation = 1.08; updated.lyricSize = 44
            updated.backgroundTransition = .crossfade; updated.backgroundTransitionDuration = 1.20
            updated.visualizerStrength = 0.74; updated.visualizerPositionY = 0.30
            updated.visualizerScale = 1.05; updated.visualizerGlow = 0.88; updated.visualizerSmoothing = 0.78; updated.visualizerDensity = 0.58
            updated.lyricPositionY = 0.58; updated.lyricAnimation = .scroll; updated.lyricGlow = 0.66; updated.lyricInactiveOpacity = 0.25; updated.lyricAnimationDuration = 0.55
        case .ethereal:
            updated.blur = 18; updated.darkness = 0.34; updated.saturation = 1.16; updated.lyricSize = 42
            updated.backgroundTransition = .crossfade; updated.backgroundTransitionDuration = 1.35
            updated.visualizerStrength = 0.86; updated.visualizerPositionY = 0.31
            updated.visualizerScale = 1.08; updated.visualizerGlow = 0.96; updated.visualizerSmoothing = 0.72; updated.visualizerDensity = 0.86
            updated.lyricPositionY = 0.60; updated.lyricAnimation = .bloom; updated.lyricGlow = 0.82; updated.lyricInactiveOpacity = 0.24; updated.lyricAnimationDuration = 0.52
        case .minimal:
            updated.blur = 4; updated.darkness = 0.28; updated.saturation = 0.92; updated.lyricSize = 38
            updated.backgroundTransition = .crossfade; updated.backgroundTransitionDuration = 0.65
            updated.visualizerStrength = 0.56; updated.visualizerPositionY = 0.22
            updated.visualizerScale = 0.92; updated.visualizerGlow = 0.32; updated.visualizerSmoothing = 0.82; updated.visualizerDensity = 0.42
            updated.lyricPositionY = 0.56; updated.lyricAnimation = .fade; updated.lyricGlow = 0.28; updated.lyricInactiveOpacity = 0.34; updated.lyricAnimationDuration = 0.30
        case .cinema:
            updated.blur = 26; updated.darkness = 0.46; updated.saturation = 1.05; updated.lyricSize = 50
            updated.backgroundTransition = .crossfade; updated.backgroundTransitionDuration = 1.40
            updated.visualizerStrength = 0.62; updated.visualizerPositionY = 0.27
            updated.visualizerScale = 1.12; updated.visualizerGlow = 0.82; updated.visualizerSmoothing = 0.75; updated.visualizerDensity = 0.48
            updated.lyricPositionY = 0.59; updated.lyricAnimation = .scroll; updated.lyricGlow = 0.74; updated.lyricInactiveOpacity = 0.20; updated.lyricAnimationDuration = 0.60
        case .electronic:
            updated.blur = 8; updated.darkness = 0.24; updated.saturation = 1.22; updated.lyricSize = 40
            updated.backgroundTransition = .crossfade; updated.backgroundTransitionDuration = 0.55
            updated.visualizerStrength = 1; updated.visualizerPositionY = 0.22
            updated.visualizerScale = 1.02; updated.visualizerGlow = 0.95; updated.visualizerSmoothing = 0.42; updated.visualizerDensity = 0.82
            updated.lyricPositionY = 0.60; updated.lyricAnimation = .karaoke; updated.lyricGlow = 0.80; updated.lyricInactiveOpacity = 0.26; updated.lyricAnimationDuration = 0.28
        }
        settings = updated // One state transaction, one preview request.
    }

    func resetLyricsStyle() {
        var updated = settings
        let defaults = RenderSettings()
        updated.lyricSize = defaults.lyricSize
        updated.lyricPositionY = defaults.lyricPositionY
        updated.lyricWidth = defaults.lyricWidth
        updated.lyricLineSpacing = defaults.lyricLineSpacing
        updated.lyricInactiveOpacity = defaults.lyricInactiveOpacity
        updated.lyricGlow = defaults.lyricGlow
        updated.lyricAnimationDuration = defaults.lyricAnimationDuration
        updated.lyricAnimation = defaults.lyricAnimation
        updated.lyricAlignment = defaults.lyricAlignment
        settings = updated
    }

    func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            previewUpdates.send(())
        } else {
            if currentTime >= max(0, duration - 0.1) { seek(to: 0) }
            player.play()
            isPlaying = true
            previewUpdates.send(())
        }
    }

    func seek(to time: Double) {
        currentTime = min(max(0, time), duration)
        player?.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func requestPreview(size: CGSize? = nil, completion: @escaping @MainActor (CGImage?, Double) -> Void) {
        let targetSize = size ?? (isPlaying ? settings.aspectRatio.realtimePreviewSize : settings.aspectRatio.previewSize)
        let snapshot = PreviewSnapshot(
            size: targetSize,
            time: currentTime,
            settings: settings,
            backgrounds: backgrounds,
            projectDuration: duration,
            lyrics: lyrics,
            analysis: audioAnalysis,
            fontName: selectedFont?.postScriptName ?? settings.fontPostScriptName
        )
        previewRenderer.request(snapshot) { [weak self] image, milliseconds in
            self?.previewRenderMilliseconds = milliseconds
            completion(image, milliseconds)
        }
    }

    func exportVideo() {
        guard !backgrounds.isEmpty, let audioURL, let analysis = audioAnalysis, !lyrics.isEmpty else {
            alertMessage = "请先导入背景、音乐和 LRC / SRT 字幕，并等待音频分析完成"
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = (audioURL.deletingPathExtension().lastPathComponent.isEmpty ? "music-video" : audioURL.deletingPathExtension().lastPathComponent) + ".mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isExporting = true
        exportFraction = 0
        exportCurrentTime = 0
        exportTotalDuration = analysis.duration
        exportMessage = "正在生成视频"
        let settings = self.settings
        let selectedPostScriptName = selectedFont?.postScriptName ?? settings.fontPostScriptName
        let exportBackgrounds = backgrounds
        let exportLyrics = lyrics
        let exporter = self.exporter
        let exportBackgroundAudioEnabled = backgroundAudioEnabled
        let exportBackgroundAudioVolume = backgroundAudioVolume
        let cancellationToken = ExportCancellationToken()
        exportCancellationToken = cancellationToken
        exportTask = Task.detached { [weak self] in
            do {
                try exporter.export(
                    to: url,
                    backgrounds: exportBackgrounds,
                    audioURL: audioURL,
                    lyrics: exportLyrics,
                    analysis: analysis,
                    settings: settings,
                    fontName: selectedPostScriptName,
                    backgroundAudioEnabled: exportBackgroundAudioEnabled,
                    backgroundAudioVolume: exportBackgroundAudioVolume,
                    cancellationToken: cancellationToken
                ) { progress in
                    Task { @MainActor [weak self] in
                        self?.exportFraction = progress.fraction
                        self?.exportCurrentTime = progress.current
                        self?.exportTotalDuration = progress.duration
                        self?.exportMessage = progress.status
                    }
                }
                await MainActor.run {
                    self?.isExporting = false
                    self?.exportMessage = "生成完成"
                    self?.exportCancellationToken = nil
                    self?.exportTask = nil
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                await MainActor.run {
                    self?.isExporting = false
                    self?.exportCancellationToken = nil
                    self?.exportTask = nil
                    if case VideoExporter.ExportError.cancelled = error {
                        try? FileManager.default.removeItem(at: url)
                        self?.exportFraction = 0
                        self?.exportCurrentTime = 0
                        self?.exportMessage = "已停止生成"
                    } else {
                        self?.alertMessage = "导出失败：\(error.localizedDescription)"
                    }
                }
            }
        }
    }

    func cancelExport() {
        guard isExporting else { return }
        exportMessage = "正在停止…"
        exportCancellationToken?.cancel()
        exportTask?.cancel()
    }

    private func stopPlayer() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        if let playbackEndObserver { NotificationCenter.default.removeObserver(playbackEndObserver) }
        player?.pause()
        player = nil
        timeObserver = nil
        playbackEndObserver = nil
        isPlaying = false
    }

    private func replacePlayer(with url: URL, at startTime: Double, resume: Bool) {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        if let playbackEndObserver { NotificationCenter.default.removeObserver(playbackEndObserver) }
        player?.pause()
        let replacement: AVPlayer
        if backgroundAudioEnabled, hasBackgroundAudio,
           let mixed = try? BackgroundAudioMixer.make(
               mainAudioURL: url,
               backgrounds: backgrounds,
               projectDuration: duration,
               backgroundAudioEnabled: true,
               backgroundVolume: backgroundAudioVolume,
               transitionDuration: settings.backgroundTransitionDuration
           ) {
            let item = AVPlayerItem(asset: mixed.composition)
            item.audioMix = mixed.audioMix
            replacement = AVPlayer(playerItem: item)
        } else {
            replacement = AVPlayer(url: url)
        }
        player = replacement
        isPlaying = resume
        timeObserver = replacement.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let seconds = time.seconds
                if seconds.isFinite { self.currentTime = self.duration > 0 ? min(seconds, self.duration) : seconds }
                if self.duration > 0, seconds >= self.duration {
                    self.isPlaying = false
                    replacement.pause()
                }
            }
        }
        playbackEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: replacement.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isPlaying = false
                if let duration = self?.duration { self?.currentTime = duration }
            }
        }
        replacement.seek(to: CMTime(seconds: min(max(0, startTime), duration), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if resume { replacement.play() }
    }

    private func schedulePlaybackMixRefresh() {
        guard audioURL != nil else { return }
        mixRefreshTask?.cancel()
        mixRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self, let audioURL = self.audioURL else { return }
            self.replacePlayer(with: audioURL, at: self.currentTime, resume: self.isPlaying)
        }
    }

    private func loadLyrics(url: URL) {
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .utf16)
                    ?? String(data: data, encoding: .utf16LittleEndian) else {
                throw NSError(domain: "SikaMTV", code: 1, userInfo: [NSLocalizedDescriptionKey: "字幕文件编码无法识别"])
            }
            lyricsURL = url
            let format: SubtitleFormat = url.pathExtension.lowercased() == "srt" ? .srt : .lrc
            lyrics = LRCParser.parse(text, format: format)
            if lyrics.isEmpty { alertMessage = "没有解析到有效的 LRC / SRT 时间标签" }
        } catch {
            alertMessage = "无法读取歌词：\(error.localizedDescription)"
        }
    }

    private func matchingSubtitle(for audioURL: URL) -> URL? {
        let directory = audioURL.deletingLastPathComponent()
        let baseName = audioURL.deletingPathExtension().lastPathComponent
        for extensionName in ["srt", "lrc"] {
            let candidate = directory.appendingPathComponent(baseName).appendingPathExtension(extensionName)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private func audioFileDuration(for url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private func persistSettings() {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "SikaMTV.RenderSettings") }
    }
}
