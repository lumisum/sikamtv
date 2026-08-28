import CoreText
import XCTest
@testable import MTVMusicVideo

final class FontManagerTests: XCTestCase {
    @MainActor
    func testBundledFontIsRegisteredAndSelectedByDefault() throws {
        let manager = FontManager()
        let bundled = try XCTUnwrap(manager.fonts.first(where: { $0.isBundled }))
        XCTAssertEqual(bundled.postScriptName, FontManager.defaultPostScriptName)
        XCTAssertEqual(RenderSettings().fontPostScriptName, bundled.postScriptName)

        let font = CTFontCreateWithName(bundled.postScriptName as CFString, 24, nil)
        XCTAssertEqual(CTFontCopyPostScriptName(font) as String, bundled.postScriptName)
    }
}
