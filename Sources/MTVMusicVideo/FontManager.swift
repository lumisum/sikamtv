import AppKit
import CoreText
import Foundation

struct FontOption: Identifiable, Hashable {
    let id: String
    let displayName: String
    let postScriptName: String
    let isImported: Bool
    let isBundled: Bool
}

@MainActor
final class FontManager: ObservableObject {
    nonisolated static let defaultPostScriptName = "sucaijishikangkangti"

    @Published private(set) var fonts: [FontOption] = []
    private var importedURLs: [URL] = []
    private var bundledURLs: [URL] = []

    init() {
        registerBundledFonts()
        refresh()
    }

    func refresh() {
        let preferred = ["PingFangSC-Regular", "SongtiSC-Regular", "STHeitiSC-Light", "Helvetica"]
        let system = preferred.compactMap { name -> FontOption? in
            let font = CTFontCreateWithName(name as CFString, 16, nil)
            let postScript = CTFontCopyPostScriptName(font) as String
            let display = CTFontCopyLocalizedName(font, kCTFontFullNameKey, nil) as String? ?? name
            return FontOption(id: "system-" + postScript, displayName: display, postScriptName: postScript, isImported: false, isBundled: false)
        }
        let bundled = bundledURLs.compactMap { url -> FontOption? in
            guard let descriptor = descriptors(for: url).first,
                  let postScript = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String else { return nil }
            return FontOption(id: "bundled-" + postScript, displayName: "素材集市康康体", postScriptName: postScript, isImported: false, isBundled: true)
        }
        let imported = importedURLs.compactMap { url -> FontOption? in
            guard let descriptor = descriptors(for: url).first,
                  let postScript = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String else { return nil }
            let display = (CTFontDescriptorCopyAttribute(descriptor, kCTFontDisplayNameAttribute) as? String) ?? url.deletingPathExtension().lastPathComponent
            return FontOption(id: "imported-" + postScript, displayName: display, postScriptName: postScript, isImported: true, isBundled: false)
        }
        fonts = bundled + system.filter { option in !bundled.contains(where: { $0.postScriptName == option.postScriptName }) } + imported
    }

    func importFont() -> FontOption? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.font]
        panel.allowsMultipleSelection = false
        panel.message = "请选择 TTF 或 OTF 字体文件"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        importedURLs.append(url)
        refresh()
        return fonts.last(where: { $0.isImported })
    }

    private func registerBundledFonts() {
        var candidates: [URL] = []
        if let packaged = Bundle.main.url(forResource: "SikaDefault", withExtension: "ttf", subdirectory: "Fonts") {
            candidates.append(packaged)
        }
        #if SWIFT_PACKAGE
        if let packageResource = Bundle.module.url(forResource: "SikaDefault", withExtension: "ttf", subdirectory: "Resources/Fonts") {
            candidates.append(packageResource)
        }
        #endif
        bundledURLs = Array(Set(candidates.map(\.standardizedFileURL)))
        for url in bundledURLs {
            _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    private func descriptors(for url: URL) -> [CTFontDescriptor] {
        CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
    }
}
