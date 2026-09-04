import CoreText
import XCTest
@testable import MTVMusicVideo

final class FontManagerTests: XCTestCase {
    @MainActor
    func testBundledFontIsRegisteredAndSelectedByDefault() throws {
        let manager = FontManager()
        let chinese = try XCTUnwrap(manager.fonts.first(where: { $0.postScriptName == FontManager.defaultChinesePostScriptName }))
        let english = try XCTUnwrap(manager.fonts.first(where: { $0.postScriptName == FontManager.defaultEnglishPostScriptName }))
        XCTAssertTrue(chinese.isBundled)
        XCTAssertTrue(english.isBundled)
        XCTAssertEqual(RenderSettings().fontPostScriptName, chinese.postScriptName)

        let font = CTFontCreateWithName(english.postScriptName as CFString, 24, nil)
        XCTAssertEqual(CTFontCopyPostScriptName(font) as String, english.postScriptName)
    }

    func testLanguageChoosesTheMatchingBundledDefault() {
        XCTAssertEqual(FontManager.recommendedPostScriptName(for: .chinese), FontManager.defaultChinesePostScriptName)
        XCTAssertEqual(FontManager.recommendedPostScriptName(for: .english), FontManager.defaultEnglishPostScriptName)
    }
}
