import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var workspace: WorkspaceState
    @State private var previewImage: NSImage?

    var body: some View {
        HStack(spacing: 0) {
            AssetsPanel()
                .frame(width: 235)
            Divider()
            PreviewPanel(previewImage: $previewImage)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            SettingsPanel()
                .frame(width: 285)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { refreshPreview() }
        .onReceive(workspace.previewUpdates.debounce(for: .milliseconds(16), scheduler: RunLoop.main)) { _ in refreshPreview() }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            for provider in providers {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in workspace.handleDropped(url: url) }
                }
            }
            return true
        }
    }

    private func refreshPreview() {
        workspace.requestPreview { image, _ in
            guard let image else { return }
            let bitmap = NSBitmapImageRep(cgImage: image)
            let updated = NSImage(size: bitmap.size)
            updated.addRepresentation(bitmap)
            previewImage = updated
        }
    }
}

struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("提示").font(.headline)
            Text(message).multilineTextAlignment(.center)
            Button("好", action: onDismiss)
                .buttonStyle(.borderedProminent)
        }
        .padding(26)
        .frame(minWidth: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 16)
    }
}

struct AssetsPanel: View {
    @EnvironmentObject private var workspace: WorkspaceState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("素材库").font(.title3.weight(.semibold))
                    Spacer()
                    Image(systemName: "square.stack.3d.up")
                        .foregroundStyle(.secondary)
                }
                Text("先导入素材，再拖入中央工作区应用。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                LibrarySectionHeader(title: "背景", systemImage: "photo.on.rectangle", action: workspace.importBackground)
                if workspace.isLoadingBackgrounds {
                    ProgressView().controlSize(.small)
                }
                if workspace.backgroundLibrary.isEmpty && !workspace.isLoadingBackgrounds {
                    LibraryEmptyRow(text: "导入图片或视频")
                } else {
                    ForEach(workspace.backgroundLibrary, id: \.url) { media in
                        BackgroundLibraryRow(media: media)
                    }
                }

                Divider().padding(.vertical, 2)
                LibrarySectionHeader(title: "音乐", systemImage: "music.note", action: workspace.importAudio)
                if workspace.audioLibrary.isEmpty {
                    LibraryEmptyRow(text: "导入 WAV / MP3 / M4A")
                } else {
                    ForEach(workspace.audioLibrary, id: \.self) { url in
                        URLLibraryRow(url: url, icon: "waveform", isActive: workspace.audioURL?.standardizedFileURL == url.standardizedFileURL, activate: { workspace.activateAudio(url) }, remove: { workspace.removeAudioFromLibrary(url) })
                    }
                }

                Divider().padding(.vertical, 2)
                LibrarySectionHeader(title: "歌词 / 字幕", systemImage: "captions.bubble", action: workspace.importLyrics)
                if workspace.lyricsLibrary.isEmpty {
                    LibraryEmptyRow(text: "导入 LRC / SRT")
                } else {
                    ForEach(workspace.lyricsLibrary, id: \.self) { url in
                        URLLibraryRow(url: url, icon: "captions.bubble", isActive: workspace.lyricsURL?.standardizedFileURL == url.standardizedFileURL, activate: { workspace.activateLyrics(url) }, remove: { workspace.removeLyricsFromLibrary(url) })
                    }
                }

                if let message = workspace.alertMessage {
                    ErrorBanner(message: message) { workspace.alertMessage = nil }
                }
                Spacer(minLength: 12)
            }
            .padding(18)
        }
    }
}

private struct LibrarySectionHeader: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage).font(.headline)
            Spacer()
            Button(action: action) { Image(systemName: "plus.circle.fill") }
                .buttonStyle(.plain)
                .help("导入素材")
        }
    }
}

private struct LibraryEmptyRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(9)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct BackgroundLibraryRow: View {
    @EnvironmentObject private var workspace: WorkspaceState
    let media: BackgroundMedia

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: media.kind == .video ? "video.fill" : "photo.fill")
                .foregroundStyle(.secondary)
            Text(media.url.lastPathComponent)
                .font(.caption)
                .lineLimit(1)
            Spacer()
            Button { workspace.activateBackground(media) } label: { Image(systemName: "plus") }
                .buttonStyle(.plain)
                .help("加入工作区")
            Button { workspace.removeBackgroundFromLibrary(media) } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("从素材库移除")
        }
        .padding(8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .onDrag { NSItemProvider(object: media.url as NSURL) }
    }
}

private struct URLLibraryRow: View {
    let url: URL
    let icon: String
    let isActive: Bool
    let activate: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon).foregroundStyle(isActive ? .green : .secondary)
            Text(url.lastPathComponent).font(.caption).lineLimit(1)
            Spacer()
            if isActive { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            Button(action: activate) { Image(systemName: "plus") }
                .buttonStyle(.plain)
                .help("加入工作区")
            Button(action: remove) { Image(systemName: "xmark.circle") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("从素材库移除")
        }
        .padding(8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .onDrag { NSItemProvider(object: url as NSURL) }
    }
}

struct AssetRow: View {
    let title: String
    let detail: String?
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage).font(.title3).frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.medium))
                    Text(detail ?? "点击导入").font(.caption).foregroundStyle(detail == nil ? .secondary : .primary).lineLimit(1)
                }
                Spacer()
                Image(systemName: detail == nil ? "plus" : "checkmark.circle.fill").foregroundStyle(detail == nil ? Color.secondary : Color.green)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(9)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct PreviewPanel: View {
    @EnvironmentObject private var workspace: WorkspaceState
    @Binding var previewImage: NSImage?

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.18))
                if let previewImage {
                    Image(nsImage: previewImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(radius: 18)
                        .padding(20)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "sparkles.tv").font(.system(size: 48)).foregroundStyle(.secondary)
                        Text("导入素材后开始预览").foregroundStyle(.secondary)
                    }
                }
            }
            .aspectRatio(previewAspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            WorkspaceDropArea()
                .frame(height: 126)
            PlaybackControls()
        }
        .padding(22)
    }

    private var previewAspectRatio: CGFloat {
        let outputSize = workspace.settings.aspectRatio.size1080
        return outputSize.width / outputSize.height
    }
}

struct WorkspaceDropArea: View {
    @EnvironmentObject private var workspace: WorkspaceState
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("工作区", systemImage: "rectangle.3.group")
                    .font(.headline)
                Text("工作区中的素材才会应用")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ActiveBackgroundGroup()
                    ActiveURLGroup(title: "音乐", icon: "music.note", url: workspace.audioURL, placeholder: "拖入音乐", clear: workspace.clearAudio, remove: nil)
                    ActiveURLGroup(title: "歌词", icon: "captions.bubble", url: workspace.lyricsURL, placeholder: "拖入 LRC / SRT", clear: workspace.clearLyrics, remove: nil)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(12)
        .background(isTargeted ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isTargeted ? Color.accentColor : Color.secondary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isTargeted) { providers in
            for provider in providers {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in workspace.activateAsset(url: url) }
                }
            }
            return true
        }
    }
}

private struct ActiveBackgroundGroup: View {
    @EnvironmentObject private var workspace: WorkspaceState

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label("背景", systemImage: "photo.stack")
                    .font(.caption.weight(.semibold))
                Spacer()
                if !workspace.backgrounds.isEmpty {
                    Button("清除") { workspace.clearBackgrounds() }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                }
            }
            if workspace.backgrounds.isEmpty {
                Text("拖入图片或视频").font(.caption2).foregroundStyle(.secondary)
            } else {
                ForEach(workspace.backgrounds, id: \.url) { media in
                    HStack(spacing: 4) {
                        Image(systemName: media.kind == .video ? "video" : "photo")
                        Text(media.url.lastPathComponent).lineLimit(1)
                        Button { workspace.removeBackground(media) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain)
                    }
                    .font(.caption2)
                }
            }
        }
        .frame(width: 190, alignment: .leading)
        .padding(9)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ActiveURLGroup: View {
    let title: String
    let icon: String
    let url: URL?
    let placeholder: String
    let clear: () -> Void
    let remove: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(title, systemImage: icon).font(.caption.weight(.semibold))
                Spacer()
                if url != nil {
                    Button("清除", action: clear).buttonStyle(.borderless).font(.caption2)
                }
            }
            HStack(spacing: 4) {
                Text(url?.lastPathComponent ?? placeholder)
                    .font(.caption2)
                    .foregroundStyle(url == nil ? .secondary : .primary)
                    .lineLimit(2)
                if let remove { Button { remove() } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
            }
        }
        .frame(width: 150, alignment: .leading)
        .padding(9)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct PlaybackControls: View {
    @EnvironmentObject private var workspace: WorkspaceState

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button { workspace.togglePlayback() } label: {
                    Image(systemName: workspace.isPlaying ? "pause.fill" : "play.fill").frame(width: 18, height: 18)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.space, modifiers: [])
                .disabled(workspace.audioURL == nil)
                Text(formatTime(workspace.currentTime)).monospacedDigit().font(.caption)
                Slider(value: timeBinding, in: 0...max(workspace.duration, 1))
                Text(formatTime(workspace.duration)).monospacedDigit().font(.caption).foregroundStyle(.secondary)
            }
            if workspace.isAnalyzingAudio {
                HStack(spacing: 8) {
                    ProgressView(value: workspace.audioAnalysisProgress)
                    Text("正在分析频谱，音乐可以先播放 · \(Int(workspace.audioAnalysisProgress * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button("取消") { workspace.cancelAudioAnalysis() }
                        .buttonStyle(.borderless)
                }
            }
            if workspace.previewRenderMilliseconds > 0 {
                Text(String(format: "预览渲染 %.0f ms", workspace.previewRenderMilliseconds))
                    .font(.caption2)
                    .foregroundStyle(workspace.previewRenderMilliseconds > 33 ? Color.orange : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func formatTime(_ time: Double) -> String {
        guard time.isFinite else { return "00:00" }
        return String(format: "%02d:%02d", Int(time) / 60, Int(time) % 60)
    }

    private var timeBinding: Binding<Double> {
        Binding<Double>(
            get: { workspace.currentTime },
            set: { value in workspace.seek(to: value) }
        )
    }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case template = "模板"
    case canvas = "画面"
    case visualizer = "视觉"
    case lyrics = "歌词"

    var id: String { rawValue }
}

struct SettingsPanel: View {
    @EnvironmentObject private var workspace: WorkspaceState
    @State private var selectedTab: SettingsTab = .template

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("样式设置").font(.title3.weight(.semibold))
                Picker("设置分类", selection: $selectedTab) {
                    ForEach(SettingsTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(18)
            .padding(.bottom, 2)

            Divider()

            ScrollView {
                tabContent
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(18)
            }
            .frame(maxHeight: .infinity)

            Divider()
            exportFooter
                .padding(18)
                .background(.bar)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .template: templateSettings
        case .canvas: canvasSettings
        case .visualizer: visualizerSettings
        case .lyrics: lyricSettings
        }
    }

    private var templateSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("视觉模板", systemImage: "wand.and.stars")
                .font(.headline)
            Text("选择模板会同时设置画面、视觉和歌词的推荐参数，之后仍可分别微调。")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(VisualTemplate.allCases) { template in
                Button { workspace.applyTemplate(template) } label: {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Color(nsColor: NSColor(cgColor: template.accent) ?? .white))
                            .frame(width: 11, height: 11)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(template.title).font(.subheadline.weight(.medium))
                            Text(template.subtitle).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if workspace.settings.template == template { Image(systemName: "checkmark.circle.fill") }
                    }
                    .padding(10)
                    .background(workspace.settings.template == template ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var canvasSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Label("画面比例", systemImage: "rectangle.on.rectangle").font(.headline)
                Picker("画面比例", selection: $workspace.settings.aspectRatio) {
                    ForEach(AspectRatio.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("1080P · 30 FPS · H.264 + AAC")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Label("背景处理", systemImage: "photo.on.rectangle.angled").font(.headline)
                SliderRow(title: "背景模糊", value: $workspace.settings.blur, range: 0...40, suffix: " px")
                SliderRow(title: "背景暗化", value: $workspace.settings.darkness, range: 0...0.8, displayMultiplier: 100, suffix: "%")
                SliderRow(title: "饱和度", value: $workspace.settings.saturation, range: 0...1.6, displayMultiplier: 100, suffix: "%")
                Toggle("播放背景视频声音", isOn: $workspace.backgroundAudioEnabled)
                    .disabled(!workspace.hasBackgroundAudio)
                if workspace.backgroundAudioEnabled && workspace.hasBackgroundAudio {
                    SliderRow(title: "背景声音音量", value: $workspace.backgroundAudioVolume, range: 0...1, displayMultiplier: 100, suffix: "%")
                }
                if workspace.backgrounds.contains(where: { $0.kind == .video }) && !workspace.hasBackgroundAudio {
                    Text("当前背景视频没有可用音轨。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Label("背景轮播", systemImage: "rectangle.2.swap").font(.headline)
                let singleVideo = workspace.backgrounds.count == 1 && workspace.backgrounds.first?.kind == .video
                if singleVideo {
                    LabeledContent("循环动画", value: "自动淡入淡出")
                } else {
                    Picker("切换动画", selection: $workspace.settings.backgroundTransition) {
                        ForEach(BackgroundTransition.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .disabled(workspace.backgrounds.count < 2)
                }
                SliderRow(title: "过渡时长", value: $workspace.settings.backgroundTransitionDuration, range: 0.2...2.5, precision: 1, suffix: " s")
                    .disabled(!singleVideo && (workspace.backgrounds.count < 2 || workspace.settings.backgroundTransition == .none))
                if singleVideo {
                    Text("视频循环处会自动融合末尾与开头画面，减少重复播放的跳切感。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let segmentDuration = workspace.backgroundSegmentDuration {
                    Text("已按音乐时长自动等分：每个背景约 \(formatDuration(segmentDuration)) 后切换。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("选择多个图片或视频后，将按音乐总时长自动等分轮播。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func formatDuration(_ duration: Double) -> String {
        duration >= 10 ? String(format: "%.0f 秒", duration) : String(format: "%.1f 秒", duration)
    }

    private var visualizerSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("音频可视化", systemImage: "waveform.path.ecg").font(.headline)
            Picker("可视化类型", selection: $workspace.settings.visualizer) {
                ForEach(VisualizerKind.allCases) { Text($0.title).tag($0) }
            }
            SliderRow(title: "响应强度", value: $workspace.settings.visualizerStrength, range: 0...1.25, displayMultiplier: 100, suffix: "%")
            SliderRow(title: "垂直位置", value: $workspace.settings.visualizerPositionY, range: 0.12...0.72, displayMultiplier: 100, suffix: "%")
            SliderRow(title: "整体大小", value: $workspace.settings.visualizerScale, range: 0.6...1.5, displayMultiplier: 100, suffix: "%")
            SliderRow(title: "光晕", value: $workspace.settings.visualizerGlow, range: 0...1, displayMultiplier: 100, suffix: "%")
            SliderRow(title: "平滑", value: $workspace.settings.visualizerSmoothing, range: 0...1, displayMultiplier: 100, suffix: "%")
            SliderRow(title: "密度", value: $workspace.settings.visualizerDensity, range: 0...1, displayMultiplier: 100, suffix: "%")
        }
    }

    private var lyricSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("歌词样式", systemImage: "captions.bubble").font(.headline)
                Spacer()
                Button("重置") { workspace.resetLyricsStyle() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            Text("字体").font(.caption.weight(.semibold))
            Picker("字体", selection: selectedFontID) {
                ForEach(workspace.fontManager.fonts) { font in
                    Text(font.displayName).tag(font.id)
                }
            }
            Button { workspace.importFont() } label: {
                Label("导入 TTF / OTF 字体", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
            Text("请确保您拥有导入字体用于当前作品的合法授权。字体仅用于生成当前画面。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Picker("歌词动画", selection: $workspace.settings.lyricAnimation) {
                ForEach(LyricAnimation.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("歌词对齐", selection: $workspace.settings.lyricAlignment) {
                ForEach(LyricAlignment.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            SliderRow(title: "字体大小", value: $workspace.settings.lyricSize, range: 24...76, suffix: " pt")
            SliderRow(title: "垂直位置", value: $workspace.settings.lyricPositionY, range: 0.28...0.82, displayMultiplier: 100, suffix: "%")
            SliderRow(title: "文字宽度", value: $workspace.settings.lyricWidth, range: 0.5...0.94, displayMultiplier: 100, suffix: "%")
            SliderRow(title: "行间距", value: $workspace.settings.lyricLineSpacing, range: 1.2...2.5, precision: 1)
            SliderRow(title: "次要歌词透明度", value: $workspace.settings.lyricInactiveOpacity, range: 0.08...0.72, displayMultiplier: 100, suffix: "%")
            SliderRow(title: "文字光晕", value: $workspace.settings.lyricGlow, range: 0...1, displayMultiplier: 100, suffix: "%")
            SliderRow(title: "动画时长", value: $workspace.settings.lyricAnimationDuration, range: 0.12...1.2, precision: 1, suffix: " s")
        }
    }

    private var selectedFontID: Binding<String> {
        Binding<String>(
            get: { workspace.selectedFont?.id ?? "" },
            set: { id in
                let font = workspace.fontManager.fonts.first(where: { $0.id == id })
                workspace.selectedFont = font
                workspace.settings.fontPostScriptName = font?.postScriptName ?? workspace.settings.fontPostScriptName
            }
        )
    }

    private var exportFooter: some View {
        VStack(spacing: 8) {
            Button { workspace.exportVideo() } label: {
                Label(workspace.isExporting ? "正在生成…" : "一键生成视频", systemImage: workspace.isExporting ? "hourglass" : "film")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(workspace.isExporting || workspace.isAnalyzingAudio || !workspace.hasRequiredMedia)
            if !workspace.hasRequiredMedia && !workspace.isAnalyzingAudio {
                Text("导入背景、音乐和字幕后即可生成视频")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if workspace.isExporting {
                ProgressView(value: workspace.exportFraction)
                Text("\(workspace.exportMessage) · \(Int(workspace.exportFraction * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(formatTime(workspace.exportCurrentTime)) / \(formatTime(workspace.exportTotalDuration))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button(role: .destructive) { workspace.cancelExport() } label: {
                    Label("停止生成", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func formatTime(_ time: Double) -> String {
        guard time.isFinite else { return "00:00" }
        return String(format: "%02d:%02d", Int(time) / 60, Int(time) % 60)
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var displayMultiplier: Double = 1
    var precision: Int = 0
    var suffix = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(String(format: "%.*f%@", precision, value * displayMultiplier, suffix)).font(.caption2).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}
