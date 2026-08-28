import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var workspace: WorkspaceState
    @State private var previewImage: NSImage?

    var body: some View {
        HStack(spacing: 0) {
            AssetsPanel()
                .frame(width: 270)
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
    @State private var searchText = ""
    @State private var filter: ResourceFilter = .all
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("资源管理器").font(.title3.weight(.semibold))
                        Text("统一管理项目素材").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: workspace.importAssets) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 27, height: 27)
                    }
                    .buttonStyle(.borderedProminent)
                    .help("同时导入图片、视频、音频或字幕")
                }

                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索资源", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 9)
                .frame(height: 30)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))

                HStack {
                    Picker("资源类型", selection: $filter) {
                        ForEach(ResourceFilter.allCases) { option in
                            Label(option.title, systemImage: option.icon).tag(option)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 150)
                    Spacer()
                    Text("\(filteredItems.count) 项")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)

            Divider()

            ScrollView {
                LazyVStack(spacing: 7) {
                    if workspace.isLoadingBackgrounds {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在读取媒体信息…").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    }
                    if filteredItems.isEmpty && !workspace.isLoadingBackgrounds {
                        ResourceLibraryEmptyState(hasSearch: !searchText.isEmpty || filter != .all)
                    } else {
                        ForEach(filteredItems) { item in
                            ResourceLibraryRow(item: item)
                        }
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: .infinity)

            Divider()
            Label("拖入文件也可加入资源库", systemImage: "arrow.down.doc")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            for provider in providers {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in workspace.handleDropped(url: url) }
                }
            }
            return true
        }
    }

    private var allItems: [ResourceLibraryItem] {
        let backgrounds = workspace.backgroundLibrary.map {
            ResourceLibraryItem(url: $0.url, kind: $0.kind == .video ? .video : .image, duration: $0.duration)
        }
        let audio = workspace.audioLibrary.map { ResourceLibraryItem(url: $0, kind: .audio, duration: 0) }
        let captions = workspace.lyricsLibrary.map { ResourceLibraryItem(url: $0, kind: .captions, duration: 0) }
        return (backgrounds + audio + captions).sorted {
            if $0.kind.order != $1.kind.order { return $0.kind.order < $1.kind.order }
            return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
    }

    private var filteredItems: [ResourceLibraryItem] {
        allItems.filter { item in
            (filter.kind == nil || filter.kind == item.kind)
                && (searchText.isEmpty || item.url.lastPathComponent.localizedCaseInsensitiveContains(searchText))
        }
    }
}

private enum ResourceLibraryKind: String, CaseIterable, Identifiable {
    case image, video, audio, captions
    var id: String { rawValue }
    var title: String {
        switch self {
        case .image: return "图片"
        case .video: return "视频"
        case .audio: return "音频"
        case .captions: return "字幕"
        }
    }
    var icon: String {
        switch self {
        case .image: return "photo.fill"
        case .video: return "video.fill"
        case .audio: return "waveform"
        case .captions: return "captions.bubble.fill"
        }
    }
    var color: Color {
        switch self {
        case .image: return .blue
        case .video: return .purple
        case .audio: return .orange
        case .captions: return .pink
        }
    }
    var order: Int {
        switch self { case .image: return 0; case .video: return 1; case .audio: return 2; case .captions: return 3 }
    }
}

private enum ResourceFilter: String, CaseIterable, Identifiable {
    case all, image, video, audio, captions
    var id: String { rawValue }
    var title: String { self == .all ? "全部资源" : kind?.title ?? "全部资源" }
    var icon: String { self == .all ? "square.grid.2x2" : kind?.icon ?? "square.grid.2x2" }
    var kind: ResourceLibraryKind? { self == .all ? nil : ResourceLibraryKind(rawValue: rawValue) }
}

private struct ResourceLibraryItem: Identifiable {
    let url: URL
    let kind: ResourceLibraryKind
    let duration: Double
    var id: String { url.standardizedFileURL.path }
}

private struct ResourceLibraryEmptyState: View {
    let hasSearch: Bool

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: hasSearch ? "magnifyingglass" : "tray.and.arrow.down")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text(hasSearch ? "没有匹配的资源" : "资源库为空")
                .font(.subheadline.weight(.medium))
            Text(hasSearch ? "更换筛选条件或搜索词" : "点击上方 +，可一次导入多种素材")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }
}

private struct ResourceLibraryRow: View {
    @EnvironmentObject private var workspace: WorkspaceState
    let item: ResourceLibraryItem

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(item.kind.color.opacity(0.15))
                Image(systemName: item.kind.icon).foregroundStyle(item.kind.color)
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.deletingPathExtension().lastPathComponent)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(item.kind.title)
                    if item.duration > 0 { Text(formatDuration(item.duration)) }
                    if isActive { Text("已应用").foregroundStyle(.green) }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: activate) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "plus.circle")
                    .foregroundStyle(isActive ? Color.green : Color.secondary)
            }
                .buttonStyle(.plain)
                .help("加入工作区")
            Button(action: remove) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("从素材库移除")
        }
        .padding(8)
        .background(isActive ? Color.green.opacity(0.055) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(isActive ? Color.green.opacity(0.20) : Color.clear))
        .onDrag { NSItemProvider(object: item.url as NSURL) }
        .contextMenu {
            Button("加入工作区", action: activate)
            Button("从资源库移除", role: .destructive, action: remove)
        }
    }

    private var isActive: Bool {
        switch item.kind {
        case .image, .video: return workspace.backgrounds.contains { $0.url.standardizedFileURL == item.url.standardizedFileURL }
        case .audio: return workspace.audioURL?.standardizedFileURL == item.url.standardizedFileURL
        case .captions: return workspace.lyricsURL?.standardizedFileURL == item.url.standardizedFileURL
        }
    }

    private func activate() {
        switch item.kind {
        case .image, .video:
            if let media = workspace.backgroundLibrary.first(where: { $0.url.standardizedFileURL == item.url.standardizedFileURL }) { workspace.activateBackground(media) }
        case .audio: workspace.activateAudio(item.url)
        case .captions: workspace.activateLyrics(item.url)
        }
    }

    private func remove() {
        switch item.kind {
        case .image, .video:
            if let media = workspace.backgroundLibrary.first(where: { $0.url.standardizedFileURL == item.url.standardizedFileURL }) { workspace.removeBackgroundFromLibrary(media) }
        case .audio: workspace.removeAudioFromLibrary(item.url)
        case .captions: workspace.removeLyricsFromLibrary(item.url)
        }
    }

    private func formatDuration(_ value: Double) -> String {
        String(format: "%d:%02d", Int(value) / 60, Int(value) % 60)
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
                .frame(height: 154)
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
        VStack(alignment: .leading, spacing: 10) {
            workspaceHeader
            workspaceSlots
        }
        .padding(13)
        .background { RoundedRectangle(cornerRadius: 13).fill(dropBackground) }
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(dropBorder, lineWidth: 1))
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

    private var readyCount: Int {
        (workspace.backgrounds.isEmpty ? 0 : 1) + (workspace.audioURL == nil ? 0 : 1) + (workspace.lyricsURL == nil ? 0 : 1)
    }

    private var readyColor: Color { readyCount == 3 ? .green : .secondary }

    private var workspaceHeader: some View {
        HStack {
            Label("项目素材", systemImage: "rectangle.3.group.fill").font(.headline)
            Text("\(readyCount)/3 已就绪")
                .font(.caption2.weight(.medium))
                .foregroundStyle(readyColor)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background { Capsule().fill(readyColor.opacity(0.10)) }
            Spacer()
            Label("资源库素材拖到这里即可应用", systemImage: "hand.draw")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var workspaceSlots: some View {
        HStack(spacing: 9) {
            ProjectBackgroundSlot()
            ProjectMaterialSlot(
                number: "02",
                title: "主音乐",
                icon: "waveform",
                tint: .orange,
                isReady: workspace.audioURL != nil,
                primary: workspace.audioURL?.deletingPathExtension().lastPathComponent ?? "拖入音乐文件",
                secondary: audioStatus,
                clear: audioClearAction
            )
            ProjectMaterialSlot(
                number: "03",
                title: "歌词字幕",
                icon: "captions.bubble.fill",
                tint: .pink,
                isReady: workspace.lyricsURL != nil,
                primary: workspace.lyricsURL?.deletingPathExtension().lastPathComponent ?? "拖入歌词或字幕",
                secondary: workspace.lyrics.isEmpty ? "LRC · SRT" : "已解析 \(workspace.lyrics.count) 条字幕",
                clear: lyricsClearAction
            )
        }
    }

    private var audioStatus: String {
        if workspace.isAnalyzingAudio { return "正在分析节拍与频谱" }
        if workspace.audioAnalysis != nil { return "频谱分析完成" }
        return "WAV · MP3 · M4A"
    }

    private var audioClearAction: (() -> Void)? {
        workspace.audioURL == nil ? nil : { workspace.clearAudio() }
    }

    private var lyricsClearAction: (() -> Void)? {
        workspace.lyricsURL == nil ? nil : { workspace.clearLyrics() }
    }

    private var dropBackground: Color {
        isTargeted ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.028)
    }

    private var dropBorder: Color {
        isTargeted ? Color.accentColor : Color.secondary.opacity(0.16)
    }
}

private struct ProjectBackgroundSlot: View {
    @EnvironmentObject private var workspace: WorkspaceState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("01").font(.caption2.monospacedDigit().weight(.bold)).foregroundStyle(.blue)
                Label("画面背景", systemImage: "photo.stack.fill").font(.caption.weight(.semibold))
                Spacer()
                if !workspace.backgrounds.isEmpty {
                    Menu {
                        ForEach(workspace.backgrounds, id: \.url) { media in
                            Button("移除 \(media.url.lastPathComponent)") { workspace.removeBackground(media) }
                        }
                        Divider()
                        Button("清除全部", role: .destructive) { workspace.clearBackgrounds() }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            Text(workspace.backgrounds.isEmpty ? "拖入图片或视频" : backgroundTitle)
                .font(.caption.weight(.medium)).lineLimit(1)
            Text(workspace.backgrounds.isEmpty ? "支持多背景自动轮播" : backgroundDetail)
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(10)
        .background(Color.blue.opacity(workspace.backgrounds.isEmpty ? 0.045 : 0.085), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.blue.opacity(workspace.backgrounds.isEmpty ? 0.10 : 0.22)))
    }

    private var backgroundTitle: String {
        workspace.backgrounds.count == 1 ? workspace.backgrounds[0].url.deletingPathExtension().lastPathComponent : "\(workspace.backgrounds.count) 个背景素材"
    }
    private var backgroundDetail: String {
        let images = workspace.backgrounds.filter { $0.kind == .image }.count
        let videos = workspace.backgrounds.count - images
        let parts = [images > 0 ? "\(images) 图片" : nil, videos > 0 ? "\(videos) 视频" : nil].compactMap { $0 }
        return parts.joined(separator: " · ") + (workspace.backgrounds.count > 1 ? " · 自动轮播" : "")
    }
}

private struct ProjectMaterialSlot: View {
    let number: String
    let title: String
    let icon: String
    let tint: Color
    let isReady: Bool
    let primary: String
    let secondary: String
    let clear: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(number).font(.caption2.monospacedDigit().weight(.bold)).foregroundStyle(tint)
                Label(title, systemImage: icon).font(.caption.weight(.semibold))
                Spacer()
                if let clear {
                    Button(action: clear) { Image(systemName: "xmark.circle") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            Text(primary).font(.caption.weight(.medium)).foregroundStyle(isReady ? .primary : .secondary).lineLimit(1)
            Text(secondary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(10)
        .background(tint.opacity(isReady ? 0.085 : 0.045), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(tint.opacity(isReady ? 0.22 : 0.10)))
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
                        HStack(spacing: 3) {
                            Circle().fill(Color(nsColor: NSColor(cgColor: template.palette.warm) ?? .orange)).frame(width: 8, height: 8)
                            Circle().fill(Color(nsColor: NSColor(cgColor: template.palette.accent) ?? .white)).frame(width: 10, height: 10)
                            Circle().fill(Color(nsColor: NSColor(cgColor: template.palette.secondary) ?? .magenta)).frame(width: 8, height: 8)
                        }
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
                Text("静态图片会自动加入缓慢运镜、色彩呼吸和音乐响应环境光。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                Section("经典") {
                    ForEach(Array(VisualizerKind.allCases.prefix(5))) { Text($0.title).tag($0) }
                }
                Section("沉浸") {
                    ForEach(Array(VisualizerKind.allCases.dropFirst(5))) { Text($0.title).tag($0) }
                }
            }
            Text(workspace.settings.visualizer.subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SliderRow(title: "音乐感知", value: $workspace.settings.musicAwareness, range: 0...1, displayMultiplier: 100, suffix: "%")
            Text("理解安静、蓄势、高潮和段落变化，并自动导演光影、色彩与运动。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SliderRow(title: "响应强度", value: $workspace.settings.visualizerStrength, range: 0...1.25, displayMultiplier: 100, suffix: "%")
            SliderRow(title: "垂直位置", value: $workspace.settings.visualizerPositionY, range: 0.12...0.72, displayMultiplier: 100, suffix: "%")
            SliderRow(title: "整体大小", value: $workspace.settings.visualizerScale, range: 0.6...1.5, displayMultiplier: 100, suffix: "%")
            SliderRow(title: "光晕", value: $workspace.settings.visualizerGlow, range: 0...1, displayMultiplier: 100, suffix: "%")
            SliderRow(title: "平滑", value: $workspace.settings.visualizerSmoothing, range: 0...1, displayMultiplier: 100, suffix: "%")
            SliderRow(title: "密度", value: $workspace.settings.visualizerDensity, range: 0...1, displayMultiplier: 100, suffix: "%")
            Divider()
            Text("统一后期").font(.caption.weight(.semibold))
            SliderRow(title: "炫丽度", value: $workspace.settings.visualizerBrilliance, range: 0...1, displayMultiplier: 100, suffix: "%")
            SliderRow(title: "背景融合", value: $workspace.settings.visualizerIntegration, range: 0...1, displayMultiplier: 100, suffix: "%")
            SliderRow(title: "拖尾长度", value: $workspace.settings.visualizerTrail, range: 0...0.85, displayMultiplier: 100, suffix: "%")
            SliderRow(title: "色彩丰富度", value: $workspace.settings.visualizerColorRichness, range: 0...1, displayMultiplier: 100, suffix: "%")
            SliderRow(title: "空间深度", value: $workspace.settings.visualizerDepth, range: 0...1, displayMultiplier: 100, suffix: "%")
            SliderRow(title: "节拍冲击", value: $workspace.settings.visualizerBeatImpact, range: 0...1, displayMultiplier: 100, suffix: "%")
            Text("统一作用于背景折射、Bloom、色散、残影和调色，不会降低歌词清晰度。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                Section("SikaMTV 默认字体") {
                    ForEach(workspace.fontManager.fonts.filter(\.isBundled)) { font in
                        Text(font.displayName).tag(font.id)
                    }
                }
                Section("系统字体") {
                    ForEach(workspace.fontManager.fonts.filter { !$0.isBundled && !$0.isImported }) { font in
                        Text(font.displayName).tag(font.id)
                    }
                }
                if workspace.fontManager.fonts.contains(where: \.isImported) {
                    Section("我的字体") {
                        ForEach(workspace.fontManager.fonts.filter(\.isImported)) { font in
                            Text(font.displayName).tag(font.id)
                        }
                    }
                }
            }
            Button { workspace.importFont() } label: {
                Label("导入 TTF / OTF 字体", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
            Text("内置默认字体由项目提供；正式发布前请确认其许可证允许随 App 分发。用户导入字体请自行确认作品授权。")
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
            Label("智能对比度会根据歌词区域的背景亮度，自动增强轮廓、阴影和柔和底衬。", systemImage: "wand.and.stars")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
