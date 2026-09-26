import CoreGraphics
import Foundation
import simd

struct AtmosphereFrame {
    var mesh = VisualizerMesh()
    var waterStrength: Float = 0
    var airStrength: Float = 0
    var airMode: Float = 0
}

/// Deterministic, music-reactive environmental motion. Every position is a
/// pure function of time and a stable seed, so seeking, preview and export
/// always produce the same frame without maintaining a particle simulation.
struct AtmosphereEngine {
    private struct Recipe {
        var cloud: CGFloat = 0
        var mist: CGFloat = 0
        var rain: CGFloat = 0
        var snow: CGFloat = 0
        var leaves: CGFloat = 0
        var petals: CGFloat = 0
        var motes: CGFloat = 0
        var fireflies: CGFloat = 0
        var sand: CGFloat = 0
        var embers: CGFloat = 0
        var rays: CGFloat = 0
        var ink: CGFloat = 0
        var neon: CGFloat = 0
        var water: CGFloat = 0
        var spray: CGFloat = 0
        var air: CGFloat = 0
        var airMode: Float = 0
        var leafTone: CGFloat = 0.5
        var petalTone: CGFloat = 0.5
    }

    private struct VisibilityProfile {
        let diffuse: CGFloat
        let emissive: CGFloat
        let fineDetail: CGFloat
        let volumeColor: CGColor
    }

    func frame(
        size: CGSize,
        features: AudioFrameFeatures,
        settings: RenderSettings,
        time: Double,
        palette: VisualPalette,
        scene: SceneColorProfile? = nil
    ) -> AtmosphereFrame {
        let preset = settings.atmospherePreset
        let intensity = CGFloat(min(1, max(0, settings.atmosphereIntensity)))
        guard preset != .off, intensity > 0.001, size.width > 0, size.height > 0 else { return AtmosphereFrame() }

        let recipe = recipe(for: preset)
        let response = CGFloat(min(1, max(0, settings.atmosphereMusicResponse)))
        let density = CGFloat(min(1, max(0, settings.atmosphereForegroundDensity)))
        let music = 0.72 + response * (
            CGFloat(features.energy) * 0.20
                + CGFloat(features.buildup) * 0.14
                + CGFloat(features.climax) * 0.12
                + CGFloat(features.beat) * 0.08
                - CGFloat(features.quiet) * 0.08
        )
        let phrase = 0.88 + sin(CGFloat(features.sectionProgress) * .pi) * response * 0.12
        let scale = size.width / max(1, settings.aspectRatio.size1080.width)
        let visibility = visibilityProfile(scene: scene, palette: palette)
        var output = AtmosphereFrame()
        output.mesh.soft.reserveCapacity(4_000)
        output.mesh.volumes.reserveCapacity(1_200)
        output.mesh.additive.reserveCapacity(10_000)
        output.mesh.radials.reserveCapacity(3_000)

        if recipe.cloud > 0 { appendClouds(&output.mesh, size: size, amount: normalized(recipe.cloud * intensity, gain: visibility.diffuse), music: music, density: density, features: features, palette: palette, volumeColor: visibility.volumeColor, time: time, scale: scale) }
        if recipe.mist > 0 { appendMist(&output.mesh, size: size, amount: normalized(recipe.mist * intensity, gain: visibility.diffuse), music: music, palette: palette, volumeColor: visibility.volumeColor, time: time) }
        if recipe.rays > 0 { appendRays(&output.mesh, size: size, amount: normalized(recipe.rays * intensity, gain: visibility.emissive), music: music, features: features, palette: palette, time: time) }
        if recipe.rain > 0 { appendRain(&output.mesh, size: size, amount: normalized(recipe.rain * intensity, gain: visibility.fineDetail), music: music, density: density, features: features, palette: palette, time: time, scale: scale) }
        if recipe.snow > 0 { appendSnow(&output.mesh, size: size, amount: normalized(recipe.snow * intensity, gain: visibility.fineDetail), music: music, density: density, features: features, palette: palette, time: time, scale: scale) }
        if recipe.leaves > 0 { appendDriftingShapes(&output.mesh, size: size, amount: recipe.leaves * intensity, music: music, density: density, features: features, palette: palette, time: time, scale: scale, petals: false, seasonalTone: recipe.leafTone) }
        if recipe.petals > 0 { appendDriftingShapes(&output.mesh, size: size, amount: recipe.petals * intensity, music: music, density: density, features: features, palette: palette, time: time, scale: scale, petals: true, seasonalTone: recipe.petalTone) }
        if recipe.motes > 0 { appendMotes(&output.mesh, size: size, amount: normalized(recipe.motes * intensity, gain: visibility.emissive), music: music, density: density, features: features, palette: palette, time: time, scale: scale) }
        if recipe.fireflies > 0 { appendFireflies(&output.mesh, size: size, amount: normalized(recipe.fireflies * intensity, gain: visibility.emissive), music: music, density: density, features: features, palette: palette, time: time, scale: scale) }
        if recipe.sand > 0 { appendSand(&output.mesh, size: size, amount: normalized(recipe.sand * intensity, gain: visibility.fineDetail), music: music, density: density, features: features, palette: palette, volumeColor: visibility.volumeColor, time: time, scale: scale) }
        if recipe.embers > 0 { appendEmbers(&output.mesh, size: size, amount: normalized(recipe.embers * intensity, gain: visibility.emissive), music: music, density: density, features: features, palette: palette, time: time, scale: scale) }
        if recipe.ink > 0 { appendInkFlow(&output.mesh, size: size, amount: normalized(recipe.ink * intensity, gain: visibility.diffuse), music: music, features: features, palette: palette, time: time, scale: scale) }
        if recipe.neon > 0 { appendNeonBokeh(&output.mesh, size: size, amount: normalized(recipe.neon * intensity, gain: visibility.emissive), music: music, density: density, features: features, palette: palette, time: time, scale: scale) }
        if recipe.water > 0 {
            let waterline = CGFloat(min(0.88, max(0.48, settings.atmosphereWaterline)))
            appendWaterSurface(&output.mesh, size: size, waterline: waterline, amount: recipe.water * intensity, music: music * phrase, features: features, palette: palette, time: time, scale: scale)
            output.waterStrength = Float(min(1, recipe.water * intensity * (0.68 + response * CGFloat(features.bass) * 0.32)))
        }
        if recipe.spray > 0 { appendWaterSpray(&output.mesh, size: size, waterline: CGFloat(settings.atmosphereWaterline), amount: recipe.spray * intensity, music: music, density: density, features: features, palette: palette, time: time, scale: scale) }
        output.airStrength = Float(min(0.42, recipe.air * intensity * music))
        output.airMode = recipe.airMode
        return output
    }

    private func recipe(for preset: AtmospherePreset) -> Recipe {
        switch preset {
        case .off: return Recipe()
        case .zenLandscape: return Recipe(cloud: 0.48, mist: 0.72, motes: 0.16, rays: 0.16, ink: 0.12, water: 0.62, air: 0.16, airMode: 1)
        case .lakesideHealing: return Recipe(cloud: 0.20, mist: 0.38, motes: 0.28, rays: 0.42, water: 0.92, spray: 0.10, air: 0.10, airMode: 1)
        case .rainyNight: return Recipe(mist: 0.46, rain: 0.92, motes: 0.08, water: 0.24, spray: 0.42, air: 0.12, airMode: 1)
        case .winterSilence: return Recipe(cloud: 0.18, mist: 0.42, snow: 0.92, motes: 0.12, air: 0.08, airMode: 1)
        case .forestBreeze: return Recipe(mist: 0.18, leaves: 0.82, motes: 0.58, rays: 0.46, air: 0.06, airMode: 1, leafTone: 0.04)
        case .springBlossom: return Recipe(cloud: 0.18, mist: 0.12, petals: 0.92, motes: 0.48, rays: 0.28, petalTone: 0.08)
        case .autumnMemory: return Recipe(mist: 0.18, leaves: 0.94, motes: 0.64, sand: 0.12, rays: 0.52, leafTone: 0.96)
        case .summerFireflies: return Recipe(mist: 0.28, motes: 0.34, fireflies: 0.96, rays: 0.08)
        case .coastalTide: return Recipe(cloud: 0.24, mist: 0.48, motes: 0.10, rays: 0.22, water: 1.0, spray: 0.54)
        case .cloudSunrise: return Recipe(cloud: 0.96, mist: 0.52, motes: 0.34, rays: 0.92, air: 0.18, airMode: 1)
        case .chineseGarden: return Recipe(mist: 0.42, petals: 0.74, motes: 0.24, ink: 0.30, water: 0.48, petalTone: 0.82)
        case .inkZen: return Recipe(mist: 0.54, motes: 0.16, ink: 0.96, water: 0.52, air: 0.20, airMode: 3)
        case .neonCity: return Recipe(mist: 0.20, rain: 0.82, neon: 0.92, water: 0.28, spray: 0.20, air: 0.08, airMode: 1)
        case .desertJourney: return Recipe(mist: 0.12, motes: 0.24, sand: 1.0, rays: 0.42, air: 0.28, airMode: 2)
        case .candleQuiet: return Recipe(mist: 0.10, motes: 0.72, embers: 0.66, rays: 0.16)
        case .epicCinema: return Recipe(cloud: 0.82, mist: 0.36, sand: 0.38, embers: 0.74, rays: 0.72, air: 0.18, airMode: 2)
        }
    }

    private func appendClouds(_ mesh: inout VisualizerMesh, size: CGSize, amount: CGFloat, music: CGFloat, density: CGFloat, features: AudioFrameFeatures, palette: VisualPalette, volumeColor: CGColor, time: Double, scale: CGFloat) {
        let clusters = max(5, Int(6 + density * 6))
        for index in 0..<clusters {
            let seed = CGFloat(index)
            let depth = 0.38 + pseudo(seed * 4.19) * 0.62
            let speed = (0.0035 + pseudo(seed * 7.11) * 0.006) * music / depth
            let progress = wrapped(pseudo(seed * 2.73) + CGFloat(time) * speed)
            let x = (progress * 1.30 - 0.15) * size.width
            let y = size.height * (0.64 + pseudo(seed * 5.81) * 0.28)
            let width = size.width * (0.12 + pseudo(seed * 3.17) * 0.17) * depth
            let height = size.height * (0.035 + pseudo(seed * 9.23) * 0.045) * depth
            let rim = VisualPalette.mix(palette.cool, palette.highlight, 0.42 + CGFloat(features.warmth) * 0.12)
            let breathing = 0.92 + sin(CGFloat(time) * 0.09 + seed * 1.7) * 0.08
            for lobe in 0..<6 {
                let offset = CGFloat(lobe) - 2.5
                let lobeSeed = seed * 2 + CGFloat(lobe)
                let center = CGPoint(
                    x: x + offset * width * 0.16,
                    y: y + sin(seed + CGFloat(lobe) * 1.3) * height * 0.22
                )
                let radiusX = width * (0.34 + pseudo(lobeSeed) * 0.22) * breathing
                let radiusY = height * (0.68 + pseudo(lobeSeed * 1.7) * 0.34)
                appendRadial(&mesh.volumes, center: center, radiusX: radiusX, radiusY: radiusY, color: gpuColor(volumeColor, alpha: amount * (0.060 + depth * 0.075)))
                appendRadial(&mesh.radials, center: CGPoint(x: center.x, y: center.y + radiusY * 0.12), radiusX: radiusX * 0.72, radiusY: radiusY * 0.58, color: gpuColor(rim, alpha: amount * (0.010 + depth * 0.020 + CGFloat(features.buildup) * 0.010)))
            }
        }
    }

    private func appendMist(_ mesh: inout VisualizerMesh, size: CGSize, amount: CGFloat, music: CGFloat, palette: VisualPalette, volumeColor: CGColor, time: Double) {
        for index in 0..<9 {
            let seed = CGFloat(index)
            let drift = sin(CGFloat(time) * (0.016 + seed * 0.0018) + seed * 1.71)
            let x = size.width * (pseudo(seed * 4.7) + drift * 0.12)
            let y = size.height * (0.12 + pseudo(seed * 7.3) * 0.68)
            let color = index.isMultiple(of: 2) ? palette.cool : palette.secondary
            let radiusX = size.width * (0.24 + pseudo(seed) * 0.24)
            let radiusY = size.height * (0.055 + pseudo(seed * 2.1) * 0.075)
            appendRadial(&mesh.volumes, center: CGPoint(x: x, y: y), radiusX: radiusX, radiusY: radiusY, color: gpuColor(VisualPalette.mix(volumeColor, color, 0.30), alpha: amount * music * (0.040 + pseudo(seed * 5.2) * 0.040)))
            appendRadial(&mesh.radials, center: CGPoint(x: x + radiusX * 0.10, y: y + radiusY * 0.08), radiusX: radiusX * 0.72, radiusY: radiusY * 0.55, color: gpuColor(color, alpha: amount * music * 0.014))
        }
    }

    private func appendRain(_ mesh: inout VisualizerMesh, size: CGSize, amount: CGFloat, music: CGFloat, density: CGFloat, features: AudioFrameFeatures, palette: VisualPalette, time: Double, scale: CGFloat) {
        let count = max(48, Int(54 + density * 100))
        let wind = size.width * (0.012 + CGFloat(features.mid) * 0.022)
        for index in 0..<count {
            let seed = CGFloat(index)
            let depth = 0.28 + pseudo(seed * 3.31) * 0.72
            let speed = (0.18 + depth * 0.34) * music
            let fall = wrapped(pseudo(seed * 6.17) + CGFloat(time) * speed)
            let x = wrapped(pseudo(seed * 9.43) + CGFloat(time) * 0.006 * depth) * size.width
            let y = size.height * (1.08 - fall * 1.18)
            let length = size.height * (0.018 + depth * 0.050 + CGFloat(features.high) * 0.010)
            let start = SIMD2(Float(x), Float(y))
            let end = SIMD2(Float(x - wind * depth), Float(y - length))
            let color = VisualPalette.mix(palette.cool, palette.highlight, 0.58)
            let alpha = amount * (0.025 + depth * 0.11 + CGFloat(features.beat) * 0.025)
            appendPolyline(&mesh.additive, points: [start, end], width: Float((1.2 + depth * 2.5) * scale), color: gpuColor(color, alpha: alpha), closed: false)
        }
    }

    private func appendSnow(_ mesh: inout VisualizerMesh, size: CGSize, amount: CGFloat, music: CGFloat, density: CGFloat, features: AudioFrameFeatures, palette: VisualPalette, time: Double, scale: CGFloat) {
        let count = max(44, Int(48 + density * 92))
        for index in 0..<count {
            let seed = CGFloat(index)
            let rawDepth = pseudo(seed * 5.17)
            let depth = rawDepth < 0.28 ? 0.28 + rawDepth * 0.50 : (rawDepth < 0.76 ? 0.52 + rawDepth * 0.36 : 0.82 + rawDepth * 0.22)
            let fall = wrapped(pseudo(seed * 2.31) + CGFloat(time) * (0.015 + depth * 0.030) * music)
            let gust = sin(CGFloat(time) * (0.14 + pseudo(seed) * 0.08) + seed) * size.width * (0.012 + CGFloat(features.transient) * 0.014)
            let x = wrapped(pseudo(seed * 8.91) + gust / max(1, size.width)) * size.width
            let y = size.height * (1.04 - fall * 1.10)
            let radius = (1.2 + depth * 3.6 + pseudo(seed * 7.7) * 1.8) * scale
            let color = VisualPalette.mix(CGColor(gray: 1, alpha: 1), palette.cool, 0.18)
            appendRadial(&mesh.radials, center: CGPoint(x: x, y: y), radiusX: radius * 3.6, radiusY: radius * 3.6, color: gpuColor(color, alpha: amount * (0.025 + depth * 0.070)))
            appendRadial(&mesh.radials, center: CGPoint(x: x, y: y), radiusX: radius, radiusY: radius, color: gpuColor(color, alpha: amount * (0.28 + depth * 0.50)))
            if depth > 0.78 {
                let arm = Float(radius * 1.65)
                let center = SIMD2(Float(x), Float(y))
                let flakeAlpha = amount * (0.20 + CGFloat(features.high) * 0.14)
                appendPolyline(&mesh.additive, points: [center - SIMD2(arm, 0), center + SIMD2(arm, 0)], width: Float(max(0.55, scale)), color: gpuColor(color, alpha: flakeAlpha), closed: false)
                appendPolyline(&mesh.additive, points: [center - SIMD2(0, arm), center + SIMD2(0, arm)], width: Float(max(0.55, scale)), color: gpuColor(color, alpha: flakeAlpha), closed: false)
            }
        }
    }

    private func appendDriftingShapes(_ mesh: inout VisualizerMesh, size: CGSize, amount: CGFloat, music: CGFloat, density: CGFloat, features: AudioFrameFeatures, palette: VisualPalette, time: Double, scale: CGFloat, petals: Bool, seasonalTone: CGFloat) {
        let count = max(22, Int(24 + density * 42))
        for index in 0..<count {
            let seed = CGFloat(index)
            let depth = 0.34 + pseudo(seed * 3.13) * 0.66
            let fall = wrapped(pseudo(seed * 6.23) + CGFloat(time) * (0.012 + depth * 0.025) * music)
            let gust = sin(CGFloat(time) * (0.10 + pseudo(seed) * 0.08) + seed * 1.9) * (0.035 + CGFloat(features.transient) * 0.055)
            let x = wrapped(pseudo(seed * 8.47) + fall * (0.10 + CGFloat(features.buildup) * 0.08) + gust) * size.width
            let y = size.height * (1.08 - fall * 1.18)
            let rotation = CGFloat(time) * (0.22 + pseudo(seed * 9.3) * 0.46) + seed
            let width = (petals ? 8.0 : 10.5) * depth * scale
            let height = (petals ? 17.0 : 25.0) * depth * scale
            let springPetal = CGColor(red: 1.00, green: 0.62, blue: 0.76, alpha: 1)
            let gardenPetal = CGColor(red: 0.96, green: 0.78, blue: 0.66, alpha: 1)
            let forestLeaf = CGColor(red: 0.30, green: 0.58, blue: 0.24, alpha: 1)
            let autumnLeaf = CGColor(red: 0.88, green: 0.40, blue: 0.10, alpha: 1)
            let seasonal = petals
                ? VisualPalette.mix(springPetal, gardenPetal, seasonalTone)
                : VisualPalette.mix(forestLeaf, autumnLeaf, seasonalTone)
            let base = VisualPalette.mix(seasonal, palette.warm, 0.30)
            let color = VisualPalette.mix(base, palette.accent, pseudo(seed * 4.1) * 0.22)
            appendLeaf(&mesh.soft, center: SIMD2(Float(x), Float(y)), width: Float(width), height: Float(height), angle: Float(rotation), color: gpuColor(color, alpha: amount * (0.28 + depth * 0.44)))
            appendRadial(&mesh.radials, center: CGPoint(x: x, y: y), radiusX: width * 1.5, radiusY: width * 1.5, color: gpuColor(color, alpha: amount * (petals ? 0.018 : 0.010) * depth))
            if depth > 0.62 {
                let tail = SIMD2(Float(x - cos(rotation) * height * 0.8), Float(y - sin(rotation) * height * 0.8))
                appendPolyline(&mesh.additive, points: [tail, SIMD2(Float(x), Float(y))], width: Float(max(0.5, depth * scale)), color: gpuColor(color, alpha: amount * 0.08), closed: false)
            }
        }
    }

    private func appendMotes(_ mesh: inout VisualizerMesh, size: CGSize, amount: CGFloat, music: CGFloat, density: CGFloat, features: AudioFrameFeatures, palette: VisualPalette, time: Double, scale: CGFloat) {
        let count = max(28, Int(30 + density * 68))
        for index in 0..<count {
            let seed = CGFloat(index)
            let drift = CGFloat(time) * (0.004 + pseudo(seed) * 0.010) * music
            let x = wrapped(pseudo(seed * 5.17) + sin(drift + seed) * 0.035) * size.width
            let y = wrapped(pseudo(seed * 8.11) + drift * 0.22) * size.height
            let energy = 0.55 + CGFloat(features.high) * 0.45
            let radius = (0.7 + pseudo(seed * 2.3) * 1.7) * scale
            let color = index.isMultiple(of: 3) ? palette.warm : palette.highlight
            appendRadial(&mesh.radials, center: CGPoint(x: x, y: y), radiusX: radius * 3.8, radiusY: radius * 3.8, color: gpuColor(color, alpha: amount * energy * 0.018))
            appendRadial(&mesh.radials, center: CGPoint(x: x, y: y), radiusX: radius, radiusY: radius, color: gpuColor(color, alpha: amount * energy * (0.10 + pseudo(seed) * 0.14)))
        }
    }

    private func appendFireflies(_ mesh: inout VisualizerMesh, size: CGSize, amount: CGFloat, music: CGFloat, density: CGFloat, features: AudioFrameFeatures, palette: VisualPalette, time: Double, scale: CGFloat) {
        let count = max(20, Int(22 + density * 38))
        let fireflyColor = VisualPalette.mix(CGColor(red: 1.0, green: 0.82, blue: 0.18, alpha: 1), palette.warm, 0.24)
        for index in 0..<count {
            let seed = CGFloat(index)
            let phase = CGFloat(time) * (0.18 + pseudo(seed) * 0.16) + seed * 2.3
            let x = pseudo(seed * 6.13) * size.width + sin(phase) * size.width * 0.035
            let y = size.height * (0.12 + pseudo(seed * 9.41) * 0.64) + cos(phase * 0.73) * size.height * 0.035
            let twinkle = (0.28 + pow(max(0, sin(phase * 1.7)), 2) * 0.72) * (0.58 + CGFloat(features.high) * 0.42)
            let radius = (1.5 + pseudo(seed) * 2.8) * scale
            appendRadial(&mesh.radials, center: CGPoint(x: x, y: y), radiusX: radius * 10, radiusY: radius * 10, color: gpuColor(fireflyColor, alpha: amount * (0.045 + twinkle * 0.16)))
            appendRadial(&mesh.radials, center: CGPoint(x: x, y: y), radiusX: radius * 2.2, radiusY: radius * 2.2, color: gpuColor(fireflyColor, alpha: amount * (0.22 + twinkle * 0.46)))
            appendRadial(&mesh.radials, center: CGPoint(x: x, y: y), radiusX: radius * 0.72, radiusY: radius * 0.72, color: gpuColor(palette.highlight, alpha: amount * (0.50 + twinkle * 0.50)))
            if index.isMultiple(of: 2) {
                let previousPhase = phase - 0.16
                let previous = SIMD2(
                    Float(pseudo(seed * 6.13) * size.width + sin(previousPhase) * size.width * 0.035),
                    Float(size.height * (0.12 + pseudo(seed * 9.41) * 0.64) + cos(previousPhase * 0.73) * size.height * 0.035)
                )
                appendPolyline(&mesh.additive, points: [previous, SIMD2(Float(x), Float(y))], width: Float(max(0.55, radius * 0.35)), color: gpuColor(fireflyColor, alpha: amount * twinkle * 0.12), closed: false)
            }
        }
    }

    private func appendSand(_ mesh: inout VisualizerMesh, size: CGSize, amount: CGFloat, music: CGFloat, density: CGFloat, features: AudioFrameFeatures, palette: VisualPalette, volumeColor: CGColor, time: Double, scale: CGFloat) {
        let count = max(50, Int(54 + density * 90))
        let color = VisualPalette.mix(palette.warm, CGColor(red: 0.86, green: 0.62, blue: 0.32, alpha: 1), 0.52)
        for layer in 0..<3 {
            let depth = CGFloat(layer) / 2
            let drift = sin(CGFloat(time) * (0.035 + depth * 0.018) + depth * 2.4) * size.width * 0.06
            appendRadial(
                &mesh.volumes,
                center: CGPoint(x: size.width * (0.46 + depth * 0.08) + drift, y: size.height * (0.10 + depth * 0.14)),
                radiusX: size.width * (0.46 - depth * 0.07),
                radiusY: size.height * (0.10 + depth * 0.04),
                color: gpuColor(VisualPalette.mix(volumeColor, color, 0.64), alpha: amount * (0.055 + CGFloat(features.buildup) * 0.045))
            )
        }
        for index in 0..<count {
            let seed = CGFloat(index)
            let speed = (0.020 + pseudo(seed) * 0.040) * music
            let x = wrapped(pseudo(seed * 7.1) + CGFloat(time) * speed) * size.width
            let yBand = pseudo(seed * 3.4)
            let y = size.height * (0.08 + yBand * 0.68 + sin(CGFloat(time) * 0.08 + seed) * 0.025)
            let length = size.width * (0.003 + pseudo(seed * 9.8) * 0.010 + CGFloat(features.buildup) * 0.004)
            let alpha = amount * (0.060 + pseudo(seed * 2.2) * 0.130)
            appendPolyline(&mesh.additive, points: [SIMD2(Float(x - length), Float(y - length * 0.10)), SIMD2(Float(x), Float(y))], width: Float((0.6 + pseudo(seed) * 1.1) * scale), color: gpuColor(color, alpha: alpha), closed: false)
        }
    }

    private func appendEmbers(_ mesh: inout VisualizerMesh, size: CGSize, amount: CGFloat, music: CGFloat, density: CGFloat, features: AudioFrameFeatures, palette: VisualPalette, time: Double, scale: CGFloat) {
        let count = max(24, Int(26 + density * 46))
        let ember = VisualPalette.mix(CGColor(red: 1.0, green: 0.30, blue: 0.06, alpha: 1), palette.warm, 0.42)
        for index in 0..<count {
            let seed = CGFloat(index)
            let rise = wrapped(pseudo(seed * 4.2) + CGFloat(time) * (0.012 + pseudo(seed) * 0.026) * music)
            let x = pseudo(seed * 8.3) * size.width + sin(CGFloat(time) * 0.16 + seed) * size.width * 0.025
            let y = size.height * (-0.05 + rise * 0.90)
            let radius = (0.8 + pseudo(seed * 2.7) * 1.8 + CGFloat(features.beat) * 0.7) * scale
            appendRadial(&mesh.radials, center: CGPoint(x: x, y: y), radiusX: radius * 6.5, radiusY: radius * 9.0, color: gpuColor(ember, alpha: amount * (0.045 + CGFloat(features.climax) * 0.085)))
            appendRadial(&mesh.radials, center: CGPoint(x: x, y: y), radiusX: radius, radiusY: radius * 1.7, color: gpuColor(palette.highlight, alpha: amount * (0.30 + pseudo(seed) * 0.38)))
            let trailLength = Float((8 + pseudo(seed * 7.2) * 18) * scale * music)
            appendPolyline(&mesh.additive, points: [SIMD2(Float(x), Float(y) - trailLength), SIMD2(Float(x), Float(y))], width: Float(max(0.55, radius * 0.42)), color: gpuColor(ember, alpha: amount * 0.16), closed: false)
        }
    }

    private func appendRays(_ mesh: inout VisualizerMesh, size: CGSize, amount: CGFloat, music: CGFloat, features: AudioFrameFeatures, palette: VisualPalette, time: Double) {
        let count = 6
        for index in 0..<count {
            let seed = CGFloat(index)
            let sourceX = size.width * (0.16 + pseudo(seed * 4.3) * 0.68)
            let drift = sin(CGFloat(time) * 0.018 + seed) * size.width * 0.03
            let spread = size.width * (0.055 + pseudo(seed * 7.2) * 0.070)
            let color = VisualPalette.mix(palette.warm, palette.highlight, 0.58)
            let alpha = amount * music * (0.040 + CGFloat(features.buildup) * 0.034 + CGFloat(features.climax) * 0.046)
            appendRadial(
                &mesh.volumes,
                center: CGPoint(x: sourceX + drift, y: size.height * 0.54),
                radiusX: spread,
                radiusY: size.height * 0.52,
                color: gpuColor(color, alpha: alpha)
            )
            appendRadial(
                &mesh.radials,
                center: CGPoint(x: sourceX + drift * 0.7, y: size.height * 0.91),
                radiusX: spread * 0.62,
                radiusY: size.height * 0.10,
                color: gpuColor(palette.highlight, alpha: alpha * 1.35)
            )
        }
    }

    private func appendInkFlow(_ mesh: inout VisualizerMesh, size: CGSize, amount: CGFloat, music: CGFloat, features: AudioFrameFeatures, palette: VisualPalette, time: Double, scale: CGFloat) {
        let width = size.width * 0.78
        for ribbon in 0..<4 {
            var points: [SIMD2<Float>] = []
            let count = 100
            points.reserveCapacity(count + 1)
            for index in 0...count {
                let p = CGFloat(index) / CGFloat(count)
                let x = size.width * 0.11 + p * width
                let y = size.height * (0.30 + CGFloat(ribbon) * 0.095)
                    + sin(p * .pi * (2.1 + CGFloat(ribbon) * 0.42) + CGFloat(time) * 0.055 + CGFloat(ribbon)) * size.height * (0.018 + CGFloat(features.mid) * 0.022)
                points.append(SIMD2(Float(x), Float(y)))
            }
            let ink = VisualPalette.mix(CGColor(gray: 0.05, alpha: 1), palette.cool, 0.28)
            appendPolyline(&mesh.soft, points: points, width: Float((24 + CGFloat(ribbon) * 14) * scale), color: gpuColor(ink, alpha: amount * music * (0.075 + CGFloat(features.bass) * 0.065)), closed: false)
            appendPolyline(&mesh.additive, points: points, width: Float(max(0.7, scale)), color: gpuColor(palette.secondary, alpha: amount * 0.030), closed: false)
            for bloom in stride(from: 10, through: 90, by: 20) {
                let point = points[bloom]
                appendRadial(&mesh.volumes, center: CGPoint(x: CGFloat(point.x), y: CGFloat(point.y)), radiusX: size.width * 0.11, radiusY: size.height * 0.060, color: gpuColor(ink, alpha: amount * (0.050 + CGFloat(features.mid) * 0.025)))
            }
        }
    }

    private func appendNeonBokeh(_ mesh: inout VisualizerMesh, size: CGSize, amount: CGFloat, music: CGFloat, density: CGFloat, features: AudioFrameFeatures, palette: VisualPalette, time: Double, scale: CGFloat) {
        let count = max(18, Int(20 + density * 30))
        for index in 0..<count {
            let seed = CGFloat(index)
            let x = pseudo(seed * 5.71) * size.width
            let y = size.height * (0.06 + pseudo(seed * 8.23) * 0.58)
            let pulse = 0.72 + sin(CGFloat(time) * (0.22 + pseudo(seed) * 0.18) + seed) * 0.18 + CGFloat(features.beat) * 0.10
            let radius = (3 + pseudo(seed * 4.9) * 8) * scale
            let color = index.isMultiple(of: 3) ? palette.accent : (index.isMultiple(of: 2) ? palette.secondary : palette.cool)
            appendRadial(&mesh.radials, center: CGPoint(x: x, y: y), radiusX: radius * 5.2, radiusY: radius * 5.2, color: gpuColor(color, alpha: amount * music * pulse * 0.075))
            appendRadial(&mesh.radials, center: CGPoint(x: x, y: y), radiusX: radius * 1.25, radiusY: radius * 1.25, color: gpuColor(color, alpha: amount * pulse * 0.32))
        }
    }

    private func appendWaterSurface(_ mesh: inout VisualizerMesh, size: CGSize, waterline: CGFloat, amount: CGFloat, music: CGFloat, features: AudioFrameFeatures, palette: VisualPalette, time: Double, scale: CGFloat) {
        let surfaceY = size.height * (1 - waterline)
        let lineCount = 7
        for line in 0..<lineCount {
            let depth = CGFloat(line) / CGFloat(max(1, lineCount - 1))
            let pointCount = 112
            var points: [SIMD2<Float>] = []
            points.reserveCapacity(pointCount + 1)
            for index in 0...pointCount {
                let p = CGFloat(index) / CGFloat(pointCount)
                let amplitude = size.height * (0.0025 + CGFloat(features.bass) * 0.0055 + CGFloat(features.beat) * 0.0018) * music * (1 + depth * 0.44)
                let wave = sin(p * .pi * (5.0 + depth * 4.0) + CGFloat(time) * (0.34 + depth * 0.16) + depth * 4.1)
                    + sin(p * .pi * 15.0 - CGFloat(time) * 0.19 + depth) * 0.24
                let y = surfaceY - depth * size.height * 0.18 + wave * amplitude
                points.append(SIMD2(Float(p * size.width), Float(y)))
            }
            let color = VisualPalette.mix(palette.cool, palette.highlight, 0.34 + depth * 0.20)
            appendPolyline(&mesh.additive, points: points, width: Float((4 + CGFloat(features.high) * 5) * scale), color: gpuColor(color, alpha: amount * (0.015 + (1 - depth) * 0.025)), closed: false)
            appendPolyline(&mesh.additive, points: points, width: Float(max(0.55, (0.7 + (1 - depth) * 0.45) * scale)), color: gpuColor(color, alpha: amount * (0.10 + (1 - depth) * 0.16)), closed: false)
            for glint in 0..<5 {
                let seed = CGFloat(line * 7 + glint)
                let center = wrapped(pseudo(seed * 4.71) + CGFloat(time) * (0.008 + depth * 0.004))
                let startIndex = min(pointCount - 5, max(0, Int(center * CGFloat(pointCount))))
                let length = 3 + Int(pseudo(seed * 8.13) * 7)
                let endIndex = min(pointCount, startIndex + length)
                guard endIndex > startIndex else { continue }
                appendPolyline(
                    &mesh.additive,
                    points: Array(points[startIndex...endIndex]),
                    width: Float((1.1 + CGFloat(features.high) * 1.6) * scale),
                    color: gpuColor(palette.highlight, alpha: amount * (0.18 + CGFloat(features.transient) * 0.18) * (1 - depth * 0.52)),
                    closed: false
                )
            }
        }

        let rippleResponse = max(CGFloat(features.beat), CGFloat(features.transient) * 0.86)
        for ripple in 0..<4 {
            let seed = CGFloat(ripple)
            let life = wrapped(CGFloat(time) * (0.16 + seed * 0.013) + pseudo(seed * 8.4))
            let fade = sin(life * .pi)
            let centerX = size.width * (0.18 + pseudo(seed * 4.2) * 0.64)
            let centerY = surfaceY - size.height * (0.025 + pseudo(seed * 6.3) * 0.12)
            let radiusX = size.width * (0.012 + life * (0.08 + rippleResponse * 0.055))
            let radiusY = radiusX * (0.10 + (1 - waterline) * 0.10)
            var ring: [SIMD2<Float>] = []
            let count = 96
            ring.reserveCapacity(count + 1)
            for index in 0...count {
                let angle = CGFloat(index) / CGFloat(count) * .pi * 2
                ring.append(SIMD2(Float(centerX + cos(angle) * radiusX), Float(centerY + sin(angle) * radiusY)))
            }
            let color = ripple.isMultiple(of: 2) ? palette.highlight : palette.cool
            appendPolyline(&mesh.additive, points: ring, width: Float((0.7 + rippleResponse * 0.7) * scale), color: gpuColor(color, alpha: amount * fade * (0.05 + rippleResponse * 0.18)), closed: true)
        }
    }

    private func appendWaterSpray(_ mesh: inout VisualizerMesh, size: CGSize, waterline: CGFloat, amount: CGFloat, music: CGFloat, density: CGFloat, features: AudioFrameFeatures, palette: VisualPalette, time: Double, scale: CGFloat) {
        let line = min(0.88, max(0.48, waterline))
        let surfaceY = size.height * (1 - line)
        let count = max(18, Int(20 + density * 34))
        for index in 0..<count {
            let seed = CGFloat(index)
            let cycle = wrapped(CGFloat(time) * (0.12 + pseudo(seed) * 0.10) + pseudo(seed * 4.7))
            let lift = sin(cycle * .pi)
            let x = pseudo(seed * 8.3) * size.width
            let y = surfaceY + lift * size.height * (0.010 + CGFloat(features.beat) * 0.025)
            let radius = (0.7 + pseudo(seed) * 1.5) * scale
            let color = VisualPalette.mix(palette.cool, palette.highlight, 0.60)
            appendRadial(&mesh.radials, center: CGPoint(x: x, y: y), radiusX: radius * 2.8, radiusY: radius * 2.8, color: gpuColor(color, alpha: amount * music * lift * (0.025 + CGFloat(features.transient) * 0.08)))
        }
    }

    private func appendLeaf(_ vertices: inout [GPUVertex], center: SIMD2<Float>, width: Float, height: Float, angle: Float, color: SIMD4<Float>) {
        let axis = SIMD2<Float>(cos(angle), sin(angle))
        let side = SIMD2<Float>(-axis.y, axis.x)
        let tip = center + axis * height * 0.5
        let tail = center - axis * height * 0.5
        let upperAxis = axis * (height * 0.12)
        let lowerAxis = axis * (height * 0.22)
        let wideSide = side * (width * 0.52)
        let narrowSide = side * (width * 0.42)
        let upperLeft = center + upperAxis + wideSide
        let lowerLeft = center - lowerAxis + narrowSide
        let lowerRight = center - lowerAxis - narrowSide
        let upperRight = center + upperAxis - wideSide
        let outline = [
            tip,
            upperLeft,
            lowerLeft,
            tail,
            lowerRight,
            upperRight
        ]
        for index in outline.indices {
            vertices.append(GPUVertex(position: center, uv: .zero, color: color))
            vertices.append(GPUVertex(position: outline[index], uv: .zero, color: color))
            vertices.append(GPUVertex(position: outline[(index + 1) % outline.count], uv: .zero, color: color))
        }
    }

    private func appendRadial(_ vertices: inout [GPUVertex], center: CGPoint, radiusX: CGFloat, radiusY: CGFloat, color: SIMD4<Float>) {
        let minX = Float(center.x - radiusX)
        let maxX = Float(center.x + radiusX)
        let minY = Float(center.y - radiusY)
        let maxY = Float(center.y + radiusY)
        vertices.append(contentsOf: [
            GPUVertex(position: SIMD2(minX, minY), uv: SIMD2(0, 0), color: color),
            GPUVertex(position: SIMD2(maxX, minY), uv: SIMD2(1, 0), color: color),
            GPUVertex(position: SIMD2(maxX, maxY), uv: SIMD2(1, 1), color: color),
            GPUVertex(position: SIMD2(minX, minY), uv: SIMD2(0, 0), color: color),
            GPUVertex(position: SIMD2(maxX, maxY), uv: SIMD2(1, 1), color: color),
            GPUVertex(position: SIMD2(minX, maxY), uv: SIMD2(0, 1), color: color)
        ])
    }

    private func appendPolyline(_ vertices: inout [GPUVertex], points: [SIMD2<Float>], width: Float, color: SIMD4<Float>, closed: Bool) {
        guard points.count > 1 else { return }
        let half = max(0.5, width * 0.5)
        let last = closed ? points.count : points.count - 1
        for index in 0..<last {
            let a = points[index]
            let b = points[(index + 1) % points.count]
            var delta = b - a
            let length = simd_length(delta)
            guard length > 0.001 else { continue }
            delta /= length
            let normal = SIMD2(-delta.y, delta.x) * half
            let a0 = a + normal
            let a1 = a - normal
            let b0 = b + normal
            let b1 = b - normal
            vertices.append(contentsOf: [
                GPUVertex(position: a0, uv: .zero, color: color),
                GPUVertex(position: a1, uv: .zero, color: color),
                GPUVertex(position: b0, uv: .zero, color: color),
                GPUVertex(position: a1, uv: .zero, color: color),
                GPUVertex(position: b1, uv: .zero, color: color),
                GPUVertex(position: b0, uv: .zero, color: color)
            ])
        }
    }

    private func gpuColor(_ color: CGColor, alpha: CGFloat) -> SIMD4<Float> {
        let rgba = VisualPalette.rgba(color)
        let value = Float(min(1, max(0, alpha)))
        return SIMD4(Float(rgba.0) * value, Float(rgba.1) * value, Float(rgba.2) * value, value)
    }

    private func normalized(_ amount: CGFloat, gain: CGFloat) -> CGFloat {
        min(1.35, max(0, amount * gain))
    }

    private func visibilityProfile(scene: SceneColorProfile?, palette: VisualPalette) -> VisibilityProfile {
        guard let scene else {
            return VisibilityProfile(
                diffuse: 1.24,
                emissive: 1.18,
                fineDetail: 1.14,
                volumeColor: VisualPalette.mix(palette.cool, palette.highlight, 0.46)
            )
        }
        let luminance = min(1, max(0, scene.luminance))
        let complexity = min(1, max(0, scene.complexity))
        let diffuse = 1.18 + complexity * 0.58 + abs(luminance - 0.46) * 0.32
        let emissive = 1.04 + luminance * 0.66 + complexity * 0.42
        let fineDetail = 1.08 + luminance * 0.30 + complexity * 0.70
        let volumeColor: CGColor
        if luminance > 0.64 {
            let charcoal = CGColor(red: 0.08, green: 0.11, blue: 0.15, alpha: 1)
            volumeColor = VisualPalette.mix(palette.cool, charcoal, 0.52 + (luminance - 0.64) * 0.55)
        } else {
            volumeColor = VisualPalette.mix(palette.cool, palette.highlight, 0.42 + (0.64 - luminance) * 0.22)
        }
        return VisibilityProfile(diffuse: diffuse, emissive: emissive, fineDetail: fineDetail, volumeColor: volumeColor)
    }

    private func pseudo(_ value: CGFloat) -> CGFloat {
        let raw = sin(value * 12.9898) * 43_758.5453
        return raw - floor(raw)
    }

    private func wrapped(_ value: CGFloat) -> CGFloat {
        let result = value.truncatingRemainder(dividingBy: 1)
        return result < 0 ? result + 1 : result
    }
}
