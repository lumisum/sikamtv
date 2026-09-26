import CoreGraphics
import XCTest
@testable import MTVMusicVideo

final class SceneColorAnalyzerTests: XCTestCase {
    func testSceneAnalysisExtractsDominantColorFromASmallCachedSample() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 240, bitsPerComponent: 8, bytesPerRow: 400 * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.82, green: 0.20, blue: 0.10, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 240))
        let profile = try XCTUnwrap(SceneColorAnalyzer.analyze(context.makeImage()))
        XCTAssertGreaterThan(profile.red, 0.75)
        XCTAssertLessThan(profile.blue, 0.18)
        XCTAssertGreaterThan(profile.warmth, 0.80)
    }

    func testSceneAnalysisKeepsTwoDominantColorsAndBuildsAHarmonizedPalette() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: 480, height: 240, bitsPerComponent: 8, bytesPerRow: 480 * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.92, green: 0.24, blue: 0.10, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 280, height: 240))
        context.setFillColor(CGColor(red: 0.08, green: 0.34, blue: 0.92, alpha: 1))
        context.fill(CGRect(x: 280, y: 0, width: 200, height: 240))
        let profile = try XCTUnwrap(SceneColorAnalyzer.analyze(context.makeImage()))
        let primaryDifference = abs(profile.primaryRed - profile.secondaryRed) + abs(profile.primaryBlue - profile.secondaryBlue)
        XCTAssertGreaterThan(primaryDifference, 0.75)
        XCTAssertGreaterThan(profile.hueDistance, 0.30)

        let palette = VisualTemplate.ethereal.palette.adapted(to: profile, strength: 0.58)
        let accent = VisualPalette.rgba(palette.accent)
        let secondary = VisualPalette.rgba(palette.secondary)
        XCTAssertGreaterThan(abs(accent.0 - secondary.0) + abs(accent.2 - secondary.2), 0.15)
    }
}
