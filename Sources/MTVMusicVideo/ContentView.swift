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
        VStack(alignment: .leading, spacing: 14) {
            Text("素材").font(.title3.weight(.semibold))
            AssetRow(title: "背景", detail: workspace.backgroundSummary, systemImage: workspace.backgrounds.count > 1 ? "photo.stack" : "photo.on.rectangle", action: workspace.importBackground)
            AssetRow(title: "音乐", detail: workspace.isAnalyzingAudio ? "正在分析 \(Int(workspace.audioAnalysisProgress * 100))%" : workspace.audioURL?.lastPathComponent, systemImage: "music.note", action: workspace.importAudio)
            AssetRow(title: "字幕 / 歌词", detail: workspace.lyricsURL?.lastPathComponent, systemImage: "captions.bubble", action: workspace.importLyrics)
            Divider().padding(.vertical, 3)
            Text("字体").font(.headline)
            Picker("字体", selection: selectedFontID) {
                ForEach(workspace.fontManager.fonts) { font in
                    Text(font.displayName).tag(font.id)
                }
            }
            .labelsHidden()
            Button { workspace.importFont() } label: {
                Label("Import Font", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
            Text("请确保您拥有导入字体用于当前作品的合法授权。软件仅使用您提供的字体生成画面。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("背景可一次选择多张图片或视频；也可以把背景、音乐或字幕文件直接拖入窗口。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message = workspace.alertMessage {
                ErrorBanner(message: message) { workspace.alertMessage = nil }
            }
            Spacer()
        }
        .padding(18)
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
            PlaybackControls()
        }
        .padding(22)
    }

    private var previewAspectRatio: CGFloat {
        let outputSize = workspace.settings.aspectRatio.size1080
        return outputSize.width / outputSize.height
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
            }
        }
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
