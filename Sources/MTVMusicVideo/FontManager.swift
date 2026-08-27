import AppKit
import CoreText
import Foundation

struct FontOption: Identifiable, Hashable {
    let id: String
    let displayName: String
    let postScriptName: String
    let isImported: Bool
}

@MainActor
final class FontManager: ObservableObject {
    @Published private(set) var fonts: [FontOption] = []
    private var importedURLs: [URL] = []

    init() {
        refresh()
    }

    func refresh() {
        let preferred = ["PingFangSC-Regular", "SongtiSC-Regular", "STHeitiSC-Light", "Helvetica"]
        let system = preferred.compactMap { name -> FontOption? in
            let font = CTFontCreateWithName(name as CFString, 16, nil)
            let postScript = CTFontCopyPostScriptName(font) as String
            let display = CTFontCopyLocalizedName(font, kCTFontFullNameKey, nil) as String? ?? name
            return FontOption(id: "system-" + postScript, displayName: display, postScriptName: postScript, isImported: false)
        }
        let imported = importedURLs.compactMap { url -> FontOption? in
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
                  let descriptor = descriptors.first,
                  let postScript = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String else { return nil }
            let display = (CTFontDescriptorCopyAttribute(descriptor, kCTFontDisplayNameAttribute) as? String) ?? url.deletingPathExtension().lastPathComponent
            return FontOption(id: "imported-" + postScript, displayName: display, postScriptName: postScript, isImported: true)
        }
        fonts = system + imported
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
}
