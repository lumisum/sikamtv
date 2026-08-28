import CoreGraphics
import XCTest
@testable import MTVMusicVideo

final class SmartDirectorTests: XCTestCase {
    func testEnergeticBeatDrivenSongSelectsElectronicDirection() {
        let song = SmartSongProfile(energy: 0.82, beat: 0.72, high: 0.54, warmth: 0.42, quiet: 0.04, dynamics: 0.31)
        let direction = SmartDirector.direct(base: RenderSettings(), song: song, scene: nil)
        XCTAssertEqual(direction.settings.template, .electronic)
        XCTAssertEqual(direction.settings.visualizer, .spectrum)
        XCTAssertGreaterThan(direction.settings.musicAwareness, 0.90)
    }

    func testQuietSongSelectsRestrainedZenDirection() {
        let song = SmartSongProfile(energy: 0.16, beat: 0.12, high: 0.18, warmth: 0.62, quiet: 0.82, dynamics: 0.08)
        let direction = SmartDirector.direct(base: RenderSettings(), song: song, scene: nil)
        XCTAssertEqual(direction.settings.template, .zen)
        XCTAssertEqual(direction.settings.visualizer, .ripple)
        XCTAssertLessThan(direction.settings.backgroundAudioWarp, 0.20)
    }

    func testExplicitMoodWinsWithoutMutatingProjectIntent() {
        var settings = RenderSettings()
        settings.smartVisualMood = .cinema
        settings.aspectRatio = .square
        settings.songTitle = "心无挂碍"
        let direction = SmartDirector.direct(base: settings, song: .silent, scene: nil)
        XCTAssertEqual(direction.settings.template, .cinema)
        XCTAssertEqual(direction.settings.visualizer, .prism)
        XCTAssertEqual(direction.settings.aspectRatio, .square)
        XCTAssertEqual(direction.settings.songTitle, "心无挂碍")
    }

    func testBrightComplexSceneGetsHighlightProtectionAndHarmonizedPalette() {
        let scene = SceneColorProfile(red: 0.88, green: 0.64, blue: 0.22, luminance: 0.70, saturation: 0.66, warmth: 0.90, complexity: 0.72)
        var settings = RenderSettings()
        settings.smartVisualMood = .ethereal
        let direction = SmartDirector.direct(base: settings, song: .silent, scene: scene)
        XCTAssertGreaterThan(direction.settings.blur, 14)
        XCTAssertGreaterThan(direction.settings.darkness, 0.18)
        XCTAssertLessThan(direction.settings.saturation, 1.0)
        XCTAssertEqual(direction.settings.backgroundOverlayOpacity, 0, "Smart color harmony must never tint the imported background")
        XCTAssertNotEqual(
            VisualPalette.rgba(direction.palette.accent).0,
            VisualPalette.rgba(VisualTemplate.ethereal.palette.accent).0,
            accuracy: 0.001
        )
    }

    func testDisablingSmartDirectorReturnsAllManualSettingsExactly() {
        var settings = RenderSettings()
        settings.smartDirectorEnabled = false
        settings.template = .minimal
        settings.visualizer = .starfield
        settings.blur = 3
        settings.visualizerStrength = 0.17
        let direction = SmartDirector.direct(
            base: settings,
            song: SmartSongProfile(energy: 1, beat: 1, high: 1, warmth: 1, quiet: 0, dynamics: 1),
            scene: SceneColorProfile(red: 1, green: 0, blue: 0, luminance: 0.5, saturation: 1, warmth: 1, complexity: 1)
        )
        XCTAssertEqual(direction.settings, settings)
        XCTAssertEqual(VisualPalette.rgba(direction.palette.accent).0, VisualPalette.rgba(settings.template.palette.accent).0, accuracy: 0.001)
    }

    func testSceneAnalysisExtractsDominantColorWithoutFullResolutionWork() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 240, bitsPerComponent: 8, bytesPerRow: 400 * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.82, green: 0.20, blue: 0.10, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 240))
        let profile = try XCTUnwrap(SmartDirector.analyzeScene(context.makeImage()))
        XCTAssertGreaterThan(profile.red, 0.75)
        XCTAssertLessThan(profile.blue, 0.18)
        XCTAssertGreaterThan(profile.warmth, 0.80)
    }
}
