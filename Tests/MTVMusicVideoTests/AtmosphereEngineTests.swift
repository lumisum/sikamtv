import CoreGraphics
import XCTest
@testable import MTVMusicVideo

final class AtmosphereEngineTests: XCTestCase {
    func testFirstReleaseContainsSixteenSelectableAtmospheresPlusOff() {
        XCTAssertEqual(AtmospherePreset.allCases.count, 17)
        XCTAssertEqual(AtmospherePreset.allCases.filter { $0 != .off }.count, 16)
        XCTAssertEqual(Set(AtmospherePreset.allCases.filter { $0 != .off }.map(\.category)), Set(["东方意境", "四季自然", "天气水域", "电影幻想"]))
    }

    func testEveryAtmosphereProducesAVisibleDeterministicLayer() {
        let engine = AtmosphereEngine()
        let size = CGSize(width: 960, height: 540)
        var settings = RenderSettings()
        settings.aspectRatio = .landscape
        settings.atmosphereIntensity = 0.72
        settings.atmosphereForegroundDensity = 0.58
        settings.atmosphereMusicResponse = 0.75
        let features = musicalFrame()

        for preset in AtmospherePreset.allCases where preset != .off {
            settings.atmospherePreset = preset
            let first = engine.frame(size: size, features: features, settings: settings, time: 3.25, palette: settings.template.palette)
            let repeated = engine.frame(size: size, features: features, settings: settings, time: 3.25, palette: settings.template.palette)
            let count = first.mesh.soft.count + first.mesh.volumes.count + first.mesh.radials.count + first.mesh.additive.count
            XCTAssertGreaterThan(count, 0, "\(preset.rawValue) must produce an atmosphere layer")
            XCTAssertEqual(first.mesh.soft.count, repeated.mesh.soft.count)
            XCTAssertEqual(first.mesh.volumes.count, repeated.mesh.volumes.count)
            XCTAssertEqual(first.mesh.radials.count, repeated.mesh.radials.count)
            XCTAssertEqual(first.mesh.additive.count, repeated.mesh.additive.count)
            XCTAssertEqual(first.mesh.soft.first?.position, repeated.mesh.soft.first?.position)
            XCTAssertEqual(first.mesh.volumes.first?.position, repeated.mesh.volumes.first?.position)
            XCTAssertEqual(first.mesh.radials.first?.position, repeated.mesh.radials.first?.position)
            XCTAssertEqual(first.mesh.additive.first?.position, repeated.mesh.additive.first?.position)
            if preset.usesWater {
                XCTAssertGreaterThan(first.waterStrength, 0, "\(preset.rawValue) should activate localized water refraction")
            } else {
                XCTAssertEqual(first.waterStrength, 0)
            }
        }
    }

    func testAtmosphereUsesVolumeMaterialAndCompensatesForBusyBrightScenes() {
        var settings = RenderSettings()
        settings.aspectRatio = .landscape
        settings.atmospherePreset = .cloudSunrise
        settings.atmosphereIntensity = 0.72
        let engine = AtmosphereEngine()
        let brightBusy = SceneColorProfile(red: 0.88, green: 0.86, blue: 0.80, luminance: 0.86, saturation: 0.10, warmth: 0.56, complexity: 0.92)
        let darkSimple = SceneColorProfile(red: 0.08, green: 0.10, blue: 0.14, luminance: 0.10, saturation: 0.06, warmth: 0.42, complexity: 0.04)

        let bright = engine.frame(size: CGSize(width: 960, height: 540), features: musicalFrame(), settings: settings, time: 4, palette: settings.template.palette, scene: brightBusy)
        let dark = engine.frame(size: CGSize(width: 960, height: 540), features: musicalFrame(), settings: settings, time: 4, palette: settings.template.palette, scene: darkSimple)

        XCTAssertFalse(bright.mesh.volumes.isEmpty, "Clouds and mist should use an alpha-blended volume material")
        let brightAlpha = bright.mesh.volumes.reduce(Float.zero) { $0 + $1.color.w }
        let darkAlpha = dark.mesh.volumes.reduce(Float.zero) { $0 + $1.color.w }
        XCTAssertGreaterThan(brightAlpha, darkAlpha, "Busy bright scenes need perceptual visibility compensation")
        XCTAssertGreaterThan(bright.airStrength, 0, "Cloud scenes should activate subtle shared-scene air motion")
        XCTAssertEqual(bright.airMode, 1)
    }

    func testMaterialRecipesSelectHeatAndInkAirMotion() {
        var settings = RenderSettings()
        let engine = AtmosphereEngine()
        settings.atmospherePreset = .desertJourney
        let desert = engine.frame(size: CGSize(width: 960, height: 540), features: musicalFrame(), settings: settings, time: 2, palette: settings.template.palette)
        settings.atmospherePreset = .inkZen
        let ink = engine.frame(size: CGSize(width: 960, height: 540), features: musicalFrame(), settings: settings, time: 2, palette: settings.template.palette)

        XCTAssertEqual(desert.airMode, 2)
        XCTAssertGreaterThan(desert.airStrength, 0)
        XCTAssertEqual(ink.airMode, 3)
        XCTAssertGreaterThan(ink.airStrength, 0)
    }

    func testOffAtmosphereDoesNoWork() {
        let frame = AtmosphereEngine().frame(
            size: CGSize(width: 960, height: 540),
            features: musicalFrame(),
            settings: RenderSettings(),
            time: 2,
            palette: RenderSettings().template.palette
        )
        XCTAssertTrue(frame.mesh.soft.isEmpty)
        XCTAssertTrue(frame.mesh.radials.isEmpty)
        XCTAssertTrue(frame.mesh.additive.isEmpty)
        XCTAssertEqual(frame.waterStrength, 0)
    }

    func testRainMotionRespondsToMusicWithoutChangingParticleCount() {
        var settings = RenderSettings()
        settings.atmospherePreset = .rainyNight
        settings.atmosphereIntensity = 0.72
        settings.atmosphereMusicResponse = 1
        settings.atmosphereForegroundDensity = 0.60
        let engine = AtmosphereEngine()
        let size = CGSize(width: 960, height: 540)
        let quiet = engine.frame(size: size, features: musicalFrame(energy: 0.08, beat: 0.04), settings: settings, time: 2.4, palette: settings.template.palette)
        let energetic = engine.frame(size: size, features: musicalFrame(energy: 0.94, beat: 0.88), settings: settings, time: 2.4, palette: settings.template.palette)

        XCTAssertEqual(quiet.mesh.additive.count, energetic.mesh.additive.count, "Music should modulate motion instead of causing unstable particle allocation")
        XCTAssertNotEqual(quiet.mesh.additive.first?.position, energetic.mesh.additive.first?.position)
    }

    func testWaterGeometryStaysBelowTheSelectedWaterline() {
        var settings = RenderSettings()
        settings.aspectRatio = .landscape
        settings.atmospherePreset = .lakesideHealing
        settings.atmosphereWaterline = 0.68
        settings.atmosphereIntensity = 0.8
        let size = CGSize(width: 960, height: 540)
        let frame = AtmosphereEngine().frame(size: size, features: musicalFrame(), settings: settings, time: 2, palette: settings.template.palette)
        let expectedSurface = Float(size.height * (1 - settings.atmosphereWaterline))
        let waterVertices = frame.mesh.additive.map(\.position.y)
        XCTAssertTrue(waterVertices.contains { $0 <= expectedSurface + 18 })
        XCTAssertGreaterThan(frame.waterStrength, 0.4)
    }

    private func musicalFrame(energy: Float = 0.68, beat: Float = 0.56) -> AudioFrameFeatures {
        AudioFrameFeatures(
            amplitude: 0.64,
            loudness: energy,
            bass: 0.72,
            mid: 0.58,
            high: 0.46,
            beat: beat,
            spectrum: (0..<96).map { 0.22 + abs(sin(Float($0) * 0.21)) * 0.58 },
            waveform: Array(repeating: 0, count: 128),
            energy: energy,
            transient: beat * 0.82,
            buildup: 0.44,
            climax: 0.38,
            quiet: max(0, 1 - energy),
            warmth: 0.58,
            sectionProgress: 0.42
        )
    }
}
