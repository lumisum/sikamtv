import CoreGraphics
import Foundation
import simd

struct VisualizerEngine {
    func mesh(
        kind: VisualizerKind,
        size: CGSize,
        features: AudioFrameFeatures,
        settings: RenderSettings,
        time: Double,
        template: VisualTemplate,
        staticBackground: Bool
    ) -> VisualizerMesh {
        var mesh = VisualizerMesh()
        guard size.width > 0, size.height > 0 else { return mesh }
        mesh.soft.reserveCapacity(12_000)
        mesh.additive.reserveCapacity(18_000)
        mesh.radials.reserveCapacity(1_200)
        let understood = features.directed(amount: Float(settings.musicAwareness))
        let spectrum = smooth(understood.spectrum, amount: settings.visualizerSmoothing)
        let frame = AudioFrameFeatures(
            amplitude: understood.amplitude,
            loudness: understood.loudness,
            bass: understood.bass,
            mid: understood.mid,
            high: understood.high,
            beat: understood.beat,
            spectrum: spectrum,
            waveform: understood.waveform,
            energy: understood.energy,
            transient: understood.transient,
            buildup: understood.buildup,
            climax: understood.climax,
            quiet: understood.quiet,
            warmth: understood.warmth,
            sectionProgress: understood.sectionProgress
        )
        let desiredCenter = CGPoint(x: size.width * 0.5, y: size.height * settings.visualizerPositionY)
        let renderScale = size.width / max(1, settings.aspectRatio.size1080.width)
        let minimum = min(size.width, size.height)
        let verticalFootprint: CGFloat
        switch kind {
        case .circle, .prism, .kaleidoscope: verticalFootprint = minimum * 0.22 * settings.visualizerScale
        case .ripple, .nebula, .starfield: verticalFootprint = minimum * 0.20 * settings.visualizerScale
        case .aurora: verticalFootprint = minimum * 0.15 * settings.visualizerScale
        case .wave, .spectrum, .mirror: verticalFootprint = minimum * 0.06
        }
        let center = CGPoint(
            x: desiredCenter.x,
            y: min(size.height - verticalFootprint, max(verticalFootprint, desiredCenter.y))
        )
        let palette = template.palette
        appendAmbientScene(
            &mesh,
            size: size,
            features: frame,
            settings: settings,
            palette: palette,
            time: time,
            staticBackground: staticBackground
        )
        guard settings.visualizerStrength > 0.001 else { return mesh }
        appendAura(&mesh, center: center, size: size, features: frame, settings: settings, palette: palette)
        switch kind {
        case .wave:
            appendWave(&mesh, center: center, size: size, features: frame, settings: settings, palette: palette, time: time, renderScale: renderScale)
        case .spectrum:
            appendElectronicSpectrum(&mesh, center: center, size: size, features: frame, settings: settings, palette: palette, mirrored: false, renderScale: renderScale)
        case .mirror:
            appendMirrorHorizon(&mesh, center: center, size: size, features: frame, settings: settings, palette: palette, time: time, renderScale: renderScale)
        case .circle:
            appendEnergyRing(&mesh, center: center, size: size, features: frame, settings: settings, palette: palette, time: time, renderScale: renderScale)
        case .ripple:
            appendZenRipple(&mesh, center: center, size: size, features: frame, settings: settings, palette: palette, time: time, renderScale: renderScale)
        case .aurora:
            appendAurora(&mesh, center: center, size: size, features: frame, settings: settings, palette: palette, time: time, renderScale: renderScale)
        case .prism:
            appendPrismTunnel(&mesh, center: center, size: size, features: frame, settings: settings, palette: palette, time: time, renderScale: renderScale)
        case .nebula:
            appendNebula(&mesh, center: center, size: size, features: frame, settings: settings, palette: palette, time: time, renderScale: renderScale)
        case .kaleidoscope:
            appendKaleidoscope(&mesh, center: center, size: size, features: frame, settings: settings, palette: palette, time: time, renderScale: renderScale)
        case .starfield:
            appendStarfield(&mesh, center: center, size: size, features: frame, settings: settings, palette: palette, time: time, renderScale: renderScale)
        }
        return mesh
    }

    /// Slow, audio-reactive light leaks keep still photos alive without adding
    /// expensive per-pixel simulation. Video backgrounds receive a subtler dose.
    private func appendAmbientScene(
        _ mesh: inout VisualizerMesh,
        size: CGSize,
        features: AudioFrameFeatures,
        settings: RenderSettings,
        palette: VisualPalette,
        time: Double,
        staticBackground: Bool
    ) {
        let glow = CGFloat(settings.visualizerGlow)
        guard glow > 0.01 else { return }
        let motionBoost: CGFloat = staticBackground ? 1 : 0.52
        let loudness = CGFloat(features.loudness)
        let bass = CGFloat(features.bass)
        let beat = CGFloat(features.beat)
        let musicalMotion = CGFloat(features.energy * 0.55 + features.buildup * 0.30 + features.climax * 0.15)
        let slowPulse = 0.78 + sin(CGFloat(time) * (0.22 + musicalMotion * 0.20)) * 0.09 + loudness * 0.12 + CGFloat(features.climax) * 0.12
        let sectionOffset = CGFloat(features.sectionProgress) * .pi * 2
        let driftX = sin(CGFloat(time) * (0.052 + musicalMotion * 0.035) + sectionOffset * 0.18)
        let driftY = cos(CGFloat(time) * (0.041 + musicalMotion * 0.028) - sectionOffset * 0.12)

        appendRadial(
            &mesh.radials,
            center: CGPoint(x: size.width * (0.20 + driftX * 0.08), y: size.height * (0.74 + driftY * 0.05)),
            radiusX: size.width * (0.46 + bass * 0.05),
            radiusY: size.height * 0.34,
            color: gpuColor(palette.accent, alpha: glow * motionBoost * (0.045 + beat * 0.025 + CGFloat(features.climax) * 0.035) * slowPulse)
        )
        appendRadial(
            &mesh.radials,
            center: CGPoint(x: size.width * (0.82 - driftX * 0.07), y: size.height * (0.35 - driftY * 0.06)),
            radiusX: size.width * 0.42,
            radiusY: size.height * (0.30 + loudness * 0.04),
            color: gpuColor(palette.secondary, alpha: glow * motionBoost * (0.038 + loudness * 0.028 + CGFloat(features.buildup) * 0.035))
        )
        appendRadial(
            &mesh.radials,
            center: CGPoint(x: size.width * (0.52 + driftY * 0.05), y: size.height * (0.88 - driftX * 0.04)),
            radiusX: size.width * 0.30,
            radiusY: size.height * 0.19,
            color: gpuColor(palette.warm, alpha: glow * motionBoost * (0.020 + beat * 0.022 + CGFloat(features.warmth) * CGFloat(features.energy) * 0.030))
        )
    }

    func placeholder(size: CGSize, time: Double, palette: VisualPalette) -> [GPUVertex] {
        var vertices: [GPUVertex] = []
        let bottom = gpuColor(CGColor(red: 0.025, green: 0.032, blue: 0.065, alpha: 1))
        let top = gpuColor(palette.accent, alpha: 0.34)
        let w = Float(size.width)
        let h = Float(size.height)
        vertices.append(contentsOf: quad(
            minX: 0, minY: 0, maxX: w, maxY: h,
            colors: (bottom, gpuColor(palette.secondary, alpha: 0.18), top, gpuColor(palette.cool, alpha: 0.12))
        ))
        for index in 0..<28 {
            let phase = CGFloat(time * (0.06 + Double(index % 3) * 0.025))
            let x = CGFloat((index * 97) % max(Int(size.width), 1))
            let y = CGFloat((index * 151) % max(Int(size.height), 1)) + sin(phase) * 20
            appendCircle(&vertices, center: SIMD2(Float(x), Float(y)), radius: 1.4, color: gpuColor(palette.ribbon(index), alpha: 0.18))
        }
        return vertices
    }

    private func appendAura(_ mesh: inout VisualizerMesh, center: CGPoint, size: CGSize, features: AudioFrameFeatures, settings: RenderSettings, palette: VisualPalette) {
        let glow = CGFloat(settings.visualizerGlow)
        let minimum = min(size.width, size.height)
        let outerRadius = minimum * (0.28 + CGFloat(features.bass) * 0.08 + CGFloat(features.energy) * 0.035) * settings.visualizerScale
        let innerRadius = minimum * (0.10 + CGFloat(features.beat) * 0.055 + CGFloat(features.transient) * 0.025) * settings.visualizerScale
        appendRadial(
            &mesh.radials,
            center: center,
            radiusX: outerRadius * 1.85,
            radiusY: outerRadius * 0.52,
            color: gpuColor(palette.cool, alpha: glow * (0.045 + CGFloat(features.loudness) * 0.065 + CGFloat(features.buildup) * 0.035))
        )
        appendRadial(
            &mesh.radials,
            center: center,
            radiusX: outerRadius * 0.78,
            radiusY: outerRadius * 0.78,
            color: gpuColor(palette.accent, alpha: glow * (0.055 + CGFloat(features.beat) * 0.080 + CGFloat(features.climax) * 0.075))
        )
        appendRadial(
            &mesh.radials,
            center: center,
            radiusX: innerRadius,
            radiusY: innerRadius,
            color: gpuColor(palette.secondary, alpha: glow * (0.040 + CGFloat(features.beat) * 0.10))
        )
    }

    private func appendWave(_ mesh: inout VisualizerMesh, center: CGPoint, size: CGSize, features: AudioFrameFeatures, settings: RenderSettings, palette: VisualPalette, time: Double, renderScale: CGFloat) {
        let values = features.waveform.isEmpty ? AudioFrameFeatures.silent.waveform : features.waveform
        let width = size.width * 0.84 * settings.visualizerScale
        let height = min(size.width, size.height) * (0.045 + CGFloat(features.loudness) * 0.085) * settings.visualizerStrength
        let startX = center.x - width / 2
        let glow = CGFloat(settings.visualizerGlow)
        appendRadial(&mesh.radials, center: center, radiusX: width * 0.54, radiusY: height * 2.8, color: gpuColor(palette.accent, alpha: 0.025 + CGFloat(features.loudness) * 0.045))
        for ribbon in 0..<5 {
            var points: [SIMD2<Float>] = []
            points.reserveCapacity(values.count)
            for index in values.indices {
                let p = CGFloat(index) / CGFloat(max(1, values.count - 1))
                let x = startX + p * width
                let smoothed = (values[max(0, index - 2)] + values[max(0, index - 1)] + values[index] * 2 + values[min(values.count - 1, index + 1)] + values[min(values.count - 1, index + 2)]) / 6
                let phase = CGFloat(ribbon - 2) * 0.55
                let drift = sin(p * .pi * (2.2 + CGFloat(ribbon) * 0.18) + CGFloat(time) * (0.22 + CGFloat(ribbon) * 0.025) + phase)
                let ribbonScale = 0.54 + CGFloat(ribbon) * 0.10
                let y = center.y + CGFloat(smoothed) * height * ribbonScale + drift * height * (0.08 + CGFloat(features.mid) * 0.10) + CGFloat(ribbon - 2) * 2.2 * renderScale
                points.append(SIMD2(Float(x), Float(y)))
            }
            if ribbon == 2 {
                appendFilledWave(&mesh.soft, points: points, baselineY: Float(center.y), top: gpuColor(palette.accent, alpha: 0.11 + CGFloat(features.loudness) * 0.09), bottom: gpuColor(palette.cool, alpha: 0.01))
            }
            let color = palette.ribbon(ribbon)
            appendPolyline(&mesh.additive, points: points, width: Float((9 + glow * 8) * renderScale), color: gpuColor(color, alpha: ribbon == 2 ? 0.075 : 0.028), closed: false)
            appendPolyline(&mesh.additive, points: points, width: Float((ribbon == 2 ? 1.75 : 1.05) * renderScale), color: gpuColor(color, alpha: ribbon == 2 ? 0.62 : 0.20 + CGFloat(features.high) * 0.12), closed: false)
        }
    }

    private func appendElectronicSpectrum(_ mesh: inout VisualizerMesh, center: CGPoint, size: CGSize, features: AudioFrameFeatures, settings: RenderSettings, palette: VisualPalette, mirrored: Bool, renderScale: CGFloat) {
        let count = max(36, Int(36 + settings.visualizerDensity * 44))
        let width = size.width * 0.84 * settings.visualizerScale
        let gap = width / CGFloat(count)
        let barWidth = max(renderScale * 2, gap * 0.52)
        let baseline = center.y
        let maxHeight = min(size.height * 0.25, min(size.width, size.height) * 0.31) * settings.visualizerStrength
        let spectrum = features.spectrum
        let glow = CGFloat(settings.visualizerGlow)
        guard !spectrum.isEmpty else { return }
        appendRadial(
            &mesh.radials,
            center: CGPoint(x: center.x, y: baseline + maxHeight * 0.16),
            radiusX: width * 0.55,
            radiusY: maxHeight * 1.45,
            color: gpuColor(palette.cool, alpha: 0.022 + CGFloat(features.loudness) * 0.035)
        )
        for index in 0..<count {
            let progress = CGFloat(index) / CGFloat(max(1, count - 1))
            let sourceProgress = mirrored ? abs(progress - 0.5) * 2 : progress
            let source = min(spectrum.count - 1, Int(pow(sourceProgress, 1.38) * CGFloat(spectrum.count - 1)))
            let value = CGFloat(spectrum[source])
            let bassBoost = sourceProgress < 0.18 ? CGFloat(features.bass) * 0.20 : 0
            let height = max(2 * renderScale, pow(value + bassBoost, 1.18) * maxHeight + CGFloat(features.beat) * maxHeight * 0.045)
            let x = center.x - width / 2 + CGFloat(index) * gap + (gap - barWidth) / 2
            let sourceColor = palette.tone(at: sourceProgress)
            let glowPad = barWidth * (0.35 + glow * 0.45)
            appendRect(&mesh.additive, x: Float(x - glowPad), y: Float(baseline), width: Float(barWidth + glowPad * 2), height: Float(height * 1.06), color: gpuColor(sourceColor, alpha: 0.045 + min(0.09, value * 0.08) + glow * 0.025))
            appendRect(&mesh.soft, x: Float(x), y: Float(baseline), width: Float(barWidth), height: Float(height), color: gpuColor(sourceColor, alpha: 0.30 + min(0.34, value * 0.34)))
            appendRect(&mesh.additive, x: Float(x), y: Float(baseline + height - max(1.5, 2.4 * renderScale)), width: Float(barWidth), height: Float(max(1.5, 2.4 * renderScale)), color: gpuColor(VisualPalette.mix(sourceColor, palette.highlight, 0.55), alpha: 0.38 + CGFloat(features.beat) * 0.24))
            appendRect(&mesh.soft, x: Float(x), y: Float(baseline - height * 0.24 - renderScale), width: Float(barWidth), height: Float(height * 0.24), color: gpuColor(sourceColor, alpha: 0.055 + value * 0.075))
        }
        appendPolyline(
            &mesh.additive,
            points: [SIMD2(Float(center.x - width / 2), Float(baseline)), SIMD2(Float(center.x + width / 2), Float(baseline))],
            width: Float(max(0.8, renderScale)),
            color: gpuColor(palette.highlight, alpha: 0.16),
            closed: false
        )
    }

    private func appendMirrorHorizon(_ mesh: inout VisualizerMesh, center: CGPoint, size: CGSize, features: AudioFrameFeatures, settings: RenderSettings, palette: VisualPalette, time: Double, renderScale: CGFloat) {
        let values = features.spectrum
        guard !values.isEmpty else { return }
        let width = size.width * 0.84 * settings.visualizerScale
        let startX = center.x - width / 2
        let maximum = min(size.height * 0.17, min(size.width, size.height) * 0.22) * settings.visualizerStrength
        let pointCount = max(72, Int(72 + settings.visualizerDensity * 48))
        var upper: [SIMD2<Float>] = []
        var lower: [SIMD2<Float>] = []
        upper.reserveCapacity(pointCount)
        lower.reserveCapacity(pointCount)
        for index in 0..<pointCount {
            let p = CGFloat(index) / CGFloat(max(1, pointCount - 1))
            let mirrored = abs(p - 0.5) * 2
            let source = min(values.count - 1, Int(pow(mirrored, 1.32) * CGFloat(values.count - 1)))
            let spectral = CGFloat(values[source])
            let breathing = sin(p * .pi * 5 + CGFloat(time) * 0.32) * CGFloat(features.mid) * 0.035
            let envelope = max(0.018, pow(spectral, 1.2) * 0.86 + breathing + CGFloat(features.beat) * (1 - mirrored) * 0.055)
            let x = startX + p * width
            upper.append(SIMD2(Float(x), Float(center.y + envelope * maximum)))
            lower.append(SIMD2(Float(x), Float(center.y - envelope * maximum * 0.72)))
        }
        appendRibbonFill(&mesh.soft, upper: upper, lower: lower, color: gpuColor(palette.accent, alpha: 0.10 + CGFloat(features.loudness) * 0.10))
        appendRadial(&mesh.radials, center: center, radiusX: width * 0.54, radiusY: maximum * 1.8, color: gpuColor(palette.secondary, alpha: 0.025 + CGFloat(features.bass) * 0.040))
        let glow = CGFloat(settings.visualizerGlow)
        appendPolyline(&mesh.additive, points: upper, width: Float((8 + glow * 8) * renderScale), color: gpuColor(palette.cool, alpha: 0.055), closed: false)
        appendPolyline(&mesh.additive, points: lower, width: Float((8 + glow * 8) * renderScale), color: gpuColor(palette.secondary, alpha: 0.045), closed: false)
        appendPolyline(&mesh.additive, points: upper, width: Float(1.65 * renderScale), color: gpuColor(palette.highlight, alpha: 0.56), closed: false)
        appendPolyline(&mesh.additive, points: lower, width: Float(1.2 * renderScale), color: gpuColor(palette.secondary, alpha: 0.36), closed: false)
        appendPolyline(&mesh.additive, points: [SIMD2(Float(startX), Float(center.y)), SIMD2(Float(startX + width), Float(center.y))], width: Float(max(0.7, renderScale)), color: gpuColor(palette.accent, alpha: 0.13), closed: false)
    }

    private func appendEnergyRing(_ mesh: inout VisualizerMesh, center: CGPoint, size: CGSize, features: AudioFrameFeatures, settings: RenderSettings, palette: VisualPalette, time: Double, renderScale: CGFloat) {
        let minimum = min(size.width, size.height)
        let radius = minimum * 0.155 * settings.visualizerScale * (1 + CGFloat(features.beat) * 0.025)
        let values = features.spectrum
        let glow = CGFloat(settings.visualizerGlow)
        guard !values.isEmpty else { return }
        appendRadial(&mesh.radials, center: center, radiusX: radius * 2.05, radiusY: radius * 2.05, color: gpuColor(palette.cool, alpha: 0.022 + CGFloat(features.loudness) * 0.035))
        appendRadial(&mesh.radials, center: center, radiusX: radius * 0.92, radiusY: radius * 0.92, color: gpuColor(palette.secondary, alpha: 0.035 + CGFloat(features.beat) * 0.055))
        let points = max(160, Int(160 + settings.visualizerDensity * 80))
        for orbit in 0..<3 {
            var ring: [SIMD2<Float>] = []
            ring.reserveCapacity(points + 1)
            for index in 0...points {
                let p = CGFloat(index) / CGFloat(points)
                let angle = p * .pi * 2 - .pi / 2 + CGFloat(time) * (orbit == 0 ? 0.008 : -0.004)
                let mirrored = p <= 0.5 ? p * 2 : (1 - p) * 2
                let source = min(values.count - 1, Int(mirrored * CGFloat(values.count - 1)))
                let value = CGFloat(values[source]) * (orbit == 0 ? 1 : 0.58)
                let displacement = pow(value, 1.28) * minimum * (orbit == 0 ? 0.040 : 0.018) * settings.visualizerStrength
                let slowDrift = sin(angle * CGFloat(2 + orbit) + CGFloat(time) * (0.20 + CGFloat(orbit) * 0.04)) * CGFloat(features.mid) * minimum * 0.0035
                let r = radius * (1 + CGFloat(orbit - 1) * 0.105) + displacement + slowDrift
                ring.append(SIMD2(Float(center.x + cos(angle) * r), Float(center.y + sin(angle) * r)))
            }
            let color = orbit == 0 ? palette.accent : (orbit == 1 ? palette.secondary : palette.cool)
            appendPolyline(&mesh.additive, points: ring, width: Float((8 + glow * 7) * renderScale), color: gpuColor(color, alpha: orbit == 0 ? 0.060 : 0.030), closed: true)
            appendPolyline(&mesh.additive, points: ring, width: Float((orbit == 0 ? 1.8 : 1.05) * renderScale), color: gpuColor(color, alpha: orbit == 0 ? 0.62 : 0.24), closed: true)
        }
        appendOrbitHighlights(&mesh, center: center, radius: radius, features: features, palette: palette, time: time, renderScale: renderScale)
    }

    private func appendZenRipple(_ mesh: inout VisualizerMesh, center: CGPoint, size: CGSize, features: AudioFrameFeatures, settings: RenderSettings, palette: VisualPalette, time: Double, renderScale: CGFloat) {
        let minimum = min(size.width, size.height)
        let baseRadius = minimum * 0.12 * settings.visualizerScale
        let values = features.spectrum
        let glow = CGFloat(settings.visualizerGlow)
        guard !values.isEmpty else { return }
        appendRadial(&mesh.radials, center: center, radiusX: baseRadius * 3.4, radiusY: baseRadius * 1.75, color: gpuColor(palette.cool, alpha: 0.022 + CGFloat(features.loudness) * 0.038))
        appendRadial(&mesh.radials, center: center, radiusX: baseRadius * 1.45, radiusY: baseRadius * 0.68, color: gpuColor(palette.accent, alpha: 0.035 + CGFloat(features.bass) * 0.055))
        let ringCount = max(5, Int(5 + settings.visualizerDensity * 3))
        for ring in 0..<ringCount {
            let ringProgress = CGFloat(ring) / CGFloat(max(1, ringCount - 1))
            let travel = (CGFloat(time) * 0.055 + ringProgress).truncatingRemainder(dividingBy: 1)
            let radius = baseRadius + travel * minimum * 0.20 + CGFloat(features.bass) * minimum * 0.012 * settings.visualizerStrength
            let ringColor = palette.tone(at: 0.18 + ringProgress * 0.72)
            var points: [SIMD2<Float>] = []
            let pointCount = 180
            points.reserveCapacity(pointCount + 1)
            for index in 0...pointCount {
                let p = CGFloat(index) / CGFloat(pointCount)
                let angle = p * .pi * 2
                let mirrored = p <= 0.5 ? p * 2 : (1 - p) * 2
                let source = min(values.count - 1, Int(mirrored * CGFloat(values.count - 1)))
                let spectral = CGFloat(values[source]) * minimum * 0.012 * settings.visualizerStrength
                let liquid = sin(angle * 3 + CGFloat(time) * 0.18 + CGFloat(ring) * 0.7) * minimum * 0.0025 * CGFloat(features.mid)
                let r = radius + spectral + liquid
                points.append(SIMD2(Float(center.x + cos(angle) * r), Float(center.y + sin(angle) * r * 0.56)))
            }
            let life = sin(travel * .pi)
            let alpha = max(0.035, life * (0.20 + CGFloat(features.beat) * 0.16) * (1 - ringProgress * 0.22))
            appendPolyline(&mesh.additive, points: points, width: Float((7 + glow * 7) * renderScale), color: gpuColor(ringColor, alpha: alpha * 0.20), closed: true)
            appendPolyline(&mesh.additive, points: points, width: Float((ring == 0 ? 1.8 : 1.05) * renderScale), color: gpuColor(ringColor, alpha: alpha), closed: true)
        }
    }

    private func appendAurora(_ mesh: inout VisualizerMesh, center: CGPoint, size: CGSize, features: AudioFrameFeatures, settings: RenderSettings, palette: VisualPalette, time: Double, renderScale: CGFloat) {
        let spectrum = features.spectrum
        guard !spectrum.isEmpty else { return }
        let width = size.width * 0.90 * settings.visualizerScale
        let startX = center.x - width / 2
        let minimum = min(size.width, size.height)
        let height = minimum * 0.19 * settings.visualizerStrength
        let curtainCount = max(5, Int(5 + settings.visualizerDensity * 4))
        let pointCount = 112
        appendRadial(&mesh.radials, center: center, radiusX: width * 0.56, radiusY: height * 1.75, color: gpuColor(palette.cool, alpha: 0.028 + CGFloat(features.loudness) * 0.045))
        for curtain in 0..<curtainCount {
            var upper: [SIMD2<Float>] = []
            var lower: [SIMD2<Float>] = []
            upper.reserveCapacity(pointCount + 1)
            lower.reserveCapacity(pointCount + 1)
            let layer = CGFloat(curtain) / CGFloat(max(1, curtainCount - 1))
            let phase = CGFloat(curtain) * 0.72
            for point in 0...pointCount {
                let p = CGFloat(point) / CGFloat(pointCount)
                let sourceProgress = min(1, max(0, p * 0.82 + layer * 0.18))
                let source = min(spectrum.count - 1, Int(sourceProgress * CGFloat(spectrum.count - 1)))
                let spectral = CGFloat(spectrum[source])
                let x = startX + p * width
                let slow = sin(p * .pi * (2.4 + layer * 1.7) + CGFloat(time) * (0.16 + layer * 0.055) + phase)
                let fine = sin(p * .pi * 8.0 - CGFloat(time) * 0.11 + phase) * CGFloat(features.high) * 0.12
                let base = center.y + (layer - 0.5) * height * 0.34
                let lift = height * (0.10 + spectral * (0.42 + layer * 0.22) + CGFloat(features.mid) * 0.12)
                let wave = (slow * 0.20 + fine) * height
                upper.append(SIMD2(Float(x), Float(base + lift + wave)))
                lower.append(SIMD2(Float(x), Float(base - lift * (0.24 + layer * 0.12) + wave * 0.34)))
            }
            let color = palette.ribbon(curtain)
            appendRibbonFill(&mesh.soft, upper: upper, lower: lower, color: gpuColor(color, alpha: 0.030 + (1 - layer) * 0.040 + CGFloat(features.loudness) * 0.025))
            appendPolyline(&mesh.additive, points: upper, width: Float((6 + CGFloat(settings.visualizerGlow) * 7) * renderScale), color: gpuColor(color, alpha: 0.025 + (1 - layer) * 0.025), closed: false)
            appendPolyline(&mesh.additive, points: upper, width: Float((0.75 + (1 - layer) * 0.75) * renderScale), color: gpuColor(color, alpha: 0.18 + (1 - layer) * 0.22), closed: false)
        }
    }

    private func appendPrismTunnel(_ mesh: inout VisualizerMesh, center: CGPoint, size: CGSize, features: AudioFrameFeatures, settings: RenderSettings, palette: VisualPalette, time: Double, renderScale: CGFloat) {
        let minimum = min(size.width, size.height)
        let spectrum = features.spectrum
        guard !spectrum.isEmpty else { return }
        let sides = 6
        let ringCount = max(7, Int(7 + settings.visualizerDensity * 5))
        let travel = (CGFloat(time) * (0.045 + CGFloat(features.loudness) * 0.035)).truncatingRemainder(dividingBy: 1)
        appendRadial(&mesh.radials, center: center, radiusX: minimum * 0.36, radiusY: minimum * 0.25, color: gpuColor(palette.accent, alpha: 0.020 + CGFloat(features.bass) * 0.045))
        for ring in 0..<ringCount {
            let depth = (CGFloat(ring) + travel) / CGFloat(ringCount)
            let source = min(spectrum.count - 1, Int(depth * CGFloat(spectrum.count - 1)))
            let spectral = CGFloat(spectrum[source])
            let radius = minimum * (0.055 + depth * 0.255) * settings.visualizerScale * (1 + CGFloat(features.beat) * 0.035)
            let rotation = CGFloat(time) * 0.018 + depth * 0.34 + spectral * 0.08
            var polygon: [SIMD2<Float>] = []
            polygon.reserveCapacity(sides)
            for side in 0..<sides {
                let angle = CGFloat(side) / CGFloat(sides) * .pi * 2 - .pi / 2 + rotation
                let frequencyRipple = 1 + spectral * settings.visualizerStrength * (side.isMultiple(of: 2) ? 0.10 : 0.035)
                polygon.append(SIMD2(Float(center.x + cos(angle) * radius * frequencyRipple), Float(center.y + sin(angle) * radius * 0.68 * frequencyRipple)))
            }
            let color = palette.tone(at: depth)
            let life = sin(depth * .pi)
            appendPolyline(&mesh.additive, points: polygon, width: Float((7 + CGFloat(settings.visualizerGlow) * 7) * renderScale), color: gpuColor(color, alpha: 0.018 + life * 0.040), closed: true)
            appendPolyline(&mesh.additive, points: polygon, width: Float((0.85 + spectral * 1.1) * renderScale), color: gpuColor(color, alpha: 0.16 + life * 0.34 + CGFloat(features.beat) * 0.08), closed: true)
        }
        for side in 0..<sides {
            let angle = CGFloat(side) / CGFloat(sides) * .pi * 2 - .pi / 2 + CGFloat(time) * 0.018
            let inner = minimum * 0.05
            let outer = minimum * 0.31 * settings.visualizerScale
            appendPolyline(
                &mesh.additive,
                points: [SIMD2(Float(center.x + cos(angle) * inner), Float(center.y + sin(angle) * inner * 0.68)), SIMD2(Float(center.x + cos(angle + 0.30) * outer), Float(center.y + sin(angle + 0.30) * outer * 0.68))],
                width: Float(max(0.65, renderScale)),
                color: gpuColor(palette.ribbon(side), alpha: 0.08 + CGFloat(features.beat) * 0.10),
                closed: false
            )
        }
    }

    private func appendNebula(_ mesh: inout VisualizerMesh, center: CGPoint, size: CGSize, features: AudioFrameFeatures, settings: RenderSettings, palette: VisualPalette, time: Double, renderScale: CGFloat) {
        let spectrum = features.spectrum
        guard !spectrum.isEmpty else { return }
        let width = size.width * 0.82 * settings.visualizerScale
        let height = min(size.height * 0.28, min(size.width, size.height) * 0.34) * settings.visualizerScale
        let bass = CGFloat(features.bass)
        appendRadial(&mesh.radials, center: CGPoint(x: center.x - width * 0.18, y: center.y + height * 0.04), radiusX: width * (0.30 + bass * 0.06), radiusY: height * 0.74, color: gpuColor(palette.secondary, alpha: 0.030 + CGFloat(features.loudness) * 0.050))
        appendRadial(&mesh.radials, center: CGPoint(x: center.x + width * 0.20, y: center.y - height * 0.05), radiusX: width * 0.34, radiusY: height * 0.68, color: gpuColor(palette.cool, alpha: 0.026 + bass * 0.045))
        appendRadial(&mesh.radials, center: center, radiusX: width * 0.18, radiusY: height * 0.52, color: gpuColor(palette.accent, alpha: 0.040 + CGFloat(features.beat) * 0.060))
        let count = max(54, Int(54 + settings.visualizerDensity * 72))
        for index in 0..<count {
            let seed = CGFloat(index)
            let source = min(spectrum.count - 1, Int(pseudo(seed * 3.17) * CGFloat(spectrum.count - 1)))
            let energy = CGFloat(spectrum[source])
            let angularSpeed = 0.010 + pseudo(seed) * 0.018
            let lifeSpeed = 0.012 + pseudo(seed * 9.41) * 0.010
            let life = (pseudo(seed * 1.83) + CGFloat(time) * lifeSpeed).truncatingRemainder(dividingBy: 1)
            let lifeFade = pow(max(0, sin(life * .pi)), 0.58)
            let angle = pseudo(seed * 5.73) * .pi * 2 + CGFloat(time) * angularSpeed + sin(life * .pi * 2) * 0.08
            let orbit = sqrt(pseudo(seed * 8.19)) * (0.30 + life * 0.08 + energy * 0.14 * settings.visualizerStrength)
            let x = center.x + cos(angle) * width * orbit
            let y = center.y + sin(angle * 1.07) * height * orbit + sin(CGFloat(time) * 0.10 + seed) * height * 0.025
            let radius = (0.75 + pseudo(seed * 2.41) * 1.8 + energy * 3.2 + CGFloat(features.high) * 1.4) * renderScale
            let color = palette.ribbon(index)
            let previousAngle = angle - angularSpeed * 7.0
            let previousOrbit = max(0.02, orbit - lifeSpeed * 1.8)
            let previous = SIMD2(
                Float(center.x + cos(previousAngle) * width * previousOrbit),
                Float(center.y + sin(previousAngle * 1.07) * height * previousOrbit)
            )
            let current = SIMD2(Float(x), Float(y))
            appendPolyline(&mesh.additive, points: [previous, current], width: Float(max(0.5, radius * 0.38)), color: gpuColor(color, alpha: lifeFade * (0.025 + energy * 0.075 + CGFloat(features.buildup) * 0.035)), closed: false)
            appendRadial(&mesh.radials, center: CGPoint(x: x, y: y), radiusX: radius * 4.0, radiusY: radius * 4.0, color: gpuColor(color, alpha: lifeFade * (0.014 + energy * 0.040)))
            appendRadial(&mesh.radials, center: CGPoint(x: x, y: y), radiusX: radius, radiusY: radius, color: gpuColor(VisualPalette.mix(color, palette.highlight, 0.45), alpha: lifeFade * (0.10 + energy * 0.28 + CGFloat(features.transient) * 0.10)))
        }
    }

    private func appendKaleidoscope(_ mesh: inout VisualizerMesh, center: CGPoint, size: CGSize, features: AudioFrameFeatures, settings: RenderSettings, palette: VisualPalette, time: Double, renderScale: CGFloat) {
        let spectrum = features.spectrum
        guard !spectrum.isEmpty else { return }
        let minimum = min(size.width, size.height)
        let petals = max(10, Int(10 + settings.visualizerDensity * 8))
        let baseRadius = minimum * 0.075 * settings.visualizerScale
        appendRadial(&mesh.radials, center: center, radiusX: minimum * 0.31, radiusY: minimum * 0.31, color: gpuColor(palette.secondary, alpha: 0.020 + CGFloat(features.loudness) * 0.045))
        for layer in 0..<2 {
            let layerScale: CGFloat = layer == 0 ? 1 : 0.62
            let rotation = CGFloat(time) * (layer == 0 ? 0.025 : -0.038) + CGFloat(layer) * (.pi / CGFloat(petals))
            for petal in 0..<petals {
                let p = CGFloat(petal) / CGFloat(petals)
                let source = min(spectrum.count - 1, Int((p <= 0.5 ? p * 2 : (1 - p) * 2) * CGFloat(spectrum.count - 1)))
                let energy = CGFloat(spectrum[source])
                let angle = p * .pi * 2 + rotation
                let inner = baseRadius * layerScale
                let outer = inner + minimum * (0.075 + energy * 0.15 * settings.visualizerStrength + CGFloat(features.beat) * 0.018) * layerScale
                let halfAngle = .pi / CGFloat(petals) * (0.62 + energy * 0.22)
                let innerPoint = SIMD2(Float(center.x + cos(angle) * inner), Float(center.y + sin(angle) * inner))
                let left = SIMD2(Float(center.x + cos(angle - halfAngle) * outer * 0.70), Float(center.y + sin(angle - halfAngle) * outer * 0.70))
                let tip = SIMD2(Float(center.x + cos(angle) * outer), Float(center.y + sin(angle) * outer))
                let right = SIMD2(Float(center.x + cos(angle + halfAngle) * outer * 0.70), Float(center.y + sin(angle + halfAngle) * outer * 0.70))
                let color = palette.tone(at: p)
                appendPetal(&mesh.soft, inner: innerPoint, left: left, tip: tip, right: right, color: gpuColor(color, alpha: layer == 0 ? 0.060 + energy * 0.055 : 0.035 + energy * 0.035))
                appendPolyline(&mesh.additive, points: [innerPoint, left, tip, right], width: Float((layer == 0 ? 1.0 : 0.7) * renderScale), color: gpuColor(color, alpha: layer == 0 ? 0.24 + energy * 0.28 : 0.13 + energy * 0.16), closed: true)
            }
        }
        appendOrbitHighlights(&mesh, center: center, radius: baseRadius * 1.42, features: features, palette: palette, time: time, renderScale: renderScale)
    }

    private func appendStarfield(_ mesh: inout VisualizerMesh, center: CGPoint, size: CGSize, features: AudioFrameFeatures, settings: RenderSettings, palette: VisualPalette, time: Double, renderScale: CGFloat) {
        let spectrum = features.spectrum
        guard !spectrum.isEmpty else { return }
        let maximum = hypot(size.width, size.height) * 0.46 * settings.visualizerScale
        let count = max(62, Int(62 + settings.visualizerDensity * 82))
        appendRadial(&mesh.radials, center: center, radiusX: min(size.width, size.height) * 0.27, radiusY: min(size.width, size.height) * 0.27, color: gpuColor(palette.cool, alpha: 0.018 + CGFloat(features.bass) * 0.040))
        for index in 0..<count {
            let seed = CGFloat(index)
            // Keep trajectory speed independent from instantaneous loudness so
            // stars retain inertia. Music changes radiance and trail length.
            let speed = 0.026 + pseudo(seed * 6.71) * 0.030
            let depth = (pseudo(seed * 2.91) + CGFloat(time) * speed).truncatingRemainder(dividingBy: 1)
            let source = min(spectrum.count - 1, Int(pseudo(seed * 4.33) * CGFloat(spectrum.count - 1)))
            let energy = CGFloat(spectrum[source])
            let lifeFade = min(1, depth / 0.10) * min(1, (1 - depth) / 0.12)
            let spiral = (depth * depth - 0.25) * (0.08 + CGFloat(features.buildup) * 0.05)
            let angle = pseudo(seed * 7.13) * .pi * 2 + CGFloat(time) * 0.006 + spiral
            let radius = maximum * pow(depth, 1.55) * (1 + CGFloat(features.climax) * 0.035)
            let streak = min(maximum * 0.15, maximum * (0.007 + depth * (0.035 + energy * 0.070 * settings.visualizerStrength + CGFloat(features.transient) * 0.030)))
            let inner = max(0, radius - streak)
            let startAngle = angle - (0.012 + depth * 0.025)
            let middleAngle = (startAngle + angle) * 0.5
            let middleRadius = (inner + radius) * 0.5
            let start = SIMD2(Float(center.x + cos(startAngle) * inner), Float(center.y + sin(startAngle) * inner * 0.72))
            let middle = SIMD2(Float(center.x + cos(middleAngle) * middleRadius), Float(center.y + sin(middleAngle) * middleRadius * 0.72))
            let end = SIMD2(Float(center.x + cos(angle) * radius), Float(center.y + sin(angle) * radius * 0.72))
            let color = palette.ribbon(index)
            appendPolyline(&mesh.additive, points: [start, middle, end], width: Float((5 + CGFloat(settings.visualizerGlow) * 6) * renderScale * max(0.35, depth)), color: gpuColor(color, alpha: lifeFade * (0.010 + depth * 0.036 + energy * 0.024)), closed: false)
            appendPolyline(&mesh.additive, points: [start, middle, end], width: Float(max(0.55, (0.55 + depth * 1.15) * renderScale)), color: gpuColor(color, alpha: lifeFade * (0.08 + depth * 0.30 + energy * 0.16 + CGFloat(features.transient) * 0.10)), closed: false)
            if index.isMultiple(of: 3) {
                let dot = (0.7 + depth * 2.0 + energy * 1.8) * renderScale
                appendRadial(&mesh.radials, center: CGPoint(x: CGFloat(end.x), y: CGFloat(end.y)), radiusX: dot, radiusY: dot, color: gpuColor(palette.highlight, alpha: lifeFade * (0.10 + depth * 0.25)))
            }
        }
    }

    private func appendEtherealFlow(_ mesh: inout VisualizerMesh, center: CGPoint, size: CGSize, features: AudioFrameFeatures, settings: RenderSettings, palette: VisualPalette, time: Double, renderScale: CGFloat) {
        let width = size.width * 0.72 * settings.visualizerScale
        let height = min(size.width, size.height) * 0.14 * settings.visualizerStrength
        let spectrum = features.spectrum
        let glow = CGFloat(settings.visualizerGlow)
        guard !spectrum.isEmpty else { return }
        for ribbon in 0..<5 {
            var points: [SIMD2<Float>] = []
            points.reserveCapacity(161)
            let phase = CGFloat(ribbon) * 0.62
            let color = palette.ribbon(ribbon)
            for point in 0...160 {
                let p = CGFloat(point) / 160
                let source = min(spectrum.count - 1, Int(p * CGFloat(spectrum.count - 1)))
                let spectral = CGFloat(spectrum[source])
                let x = center.x - width / 2 + p * width
                let waveformIndex = min(features.waveform.count - 1, Int(p * CGFloat(max(1, features.waveform.count - 1))))
                let waveform = features.waveform.isEmpty ? 0 : CGFloat(features.waveform[waveformIndex])
                let flow = sin(p * .pi * 4.5 + CGFloat(time) * (0.22 + CGFloat(ribbon) * 0.025) + phase)
                let y = center.y + flow * height * (0.22 + spectral * 0.58) + waveform * height * 0.34 + (CGFloat(ribbon) - 2) * 5 * renderScale
                points.append(SIMD2(Float(x), Float(y)))
            }
            let alpha: CGFloat = ribbon == 2 ? 0.82 : 0.18 + CGFloat(features.high) * 0.16
            appendPolyline(&mesh.additive, points: points, width: Float((ribbon == 2 ? 7.5 : CGFloat(8 + Double(ribbon) * 1.4)) * renderScale * (0.65 + glow * 0.5)), color: gpuColor(color, alpha: min(0.28, alpha * 0.45)), closed: false)
            appendPolyline(&mesh.additive, points: points, width: Float((ribbon == 2 ? 2.3 : CGFloat(3.5 + Double(ribbon) * 1.6)) * renderScale), color: gpuColor(color, alpha: alpha), closed: false)
        }
        appendParticles(&mesh, center: center, radius: width * 0.48, features: features, settings: settings, palette: palette, time: time, renderScale: renderScale)
    }

    private func appendOrbitHighlights(_ mesh: inout VisualizerMesh, center: CGPoint, radius: CGFloat, features: AudioFrameFeatures, palette: VisualPalette, time: Double, renderScale: CGFloat) {
        for index in 0..<3 {
            let angle = CGFloat(time) * (0.08 + CGFloat(index) * 0.018) + CGFloat(index) * (.pi * 2 / 3)
            let orbit = radius * (0.86 + CGFloat(index) * 0.10)
            let point = CGPoint(x: center.x + cos(angle) * orbit, y: center.y + sin(angle) * orbit)
            let dot = (2.2 + CGFloat(features.high) * 2.2 + CGFloat(features.beat) * 1.8) * renderScale
            appendRadial(&mesh.radials, center: point, radiusX: dot * 4.2, radiusY: dot * 4.2, color: gpuColor(palette.ribbon(index), alpha: 0.055 + CGFloat(features.high) * 0.075))
            appendRadial(&mesh.radials, center: point, radiusX: dot, radiusY: dot, color: gpuColor(palette.highlight, alpha: 0.28 + CGFloat(features.beat) * 0.18))
        }
    }

    private func appendParticles(_ mesh: inout VisualizerMesh, center: CGPoint, radius: CGFloat, features: AudioFrameFeatures, settings: RenderSettings, palette: VisualPalette, time: Double, renderScale: CGFloat) {
        let count = max(18, Int(18 + settings.visualizerDensity * 58))
        let intensity = CGFloat(features.high * 0.62 + features.beat * 0.38)
        guard intensity > 0.025 else { return }
        let glow = CGFloat(settings.visualizerGlow)
        for index in 0..<count {
            let seed = CGFloat(index)
            let angle = seed * 2.399963 + CGFloat(time) * (0.025 + CGFloat(index % 5) * 0.006)
            let audioPush = 1 + CGFloat(features.beat) * (0.08 + CGFloat(index % 7) * 0.008)
            let orbit = radius * (0.25 + pseudo(seed * 4.37) * 0.75) * audioPush
            let x = center.x + cos(angle) * orbit
            let y = center.y + sin(angle * 1.13) * orbit * 0.58
            let color = palette.ribbon(index)
            let dot = (1.0 + pseudo(seed * 8.91) * 3.2 + intensity * 2.4) * renderScale
            let halo = dot * (2.2 + glow * 1.4)
            appendCircle(&mesh.additive, center: SIMD2(Float(x), Float(y)), radius: Float(halo / 2), color: gpuColor(color, alpha: 0.08 + intensity * 0.12))
            appendCircle(&mesh.additive, center: SIMD2(Float(x), Float(y)), radius: Float(dot / 2), color: gpuColor(color, alpha: 0.16 + intensity * (0.22 + pseudo(seed) * 0.28)))
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

    private func appendRect(_ vertices: inout [GPUVertex], x: Float, y: Float, width: Float, height: Float, color: SIMD4<Float>) {
        vertices.append(contentsOf: quad(minX: x, minY: y, maxX: x + width, maxY: y + height, colors: (color, color, color, color)))
    }

    private func appendCircle(_ vertices: inout [GPUVertex], center: SIMD2<Float>, radius: Float, color: SIMD4<Float>) {
        appendRect(&vertices, x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2, color: color)
    }

    private func appendFilledWave(_ vertices: inout [GPUVertex], points: [SIMD2<Float>], baselineY: Float, top: SIMD4<Float>, bottom: SIMD4<Float>) {
        guard points.count > 1 else { return }
        for index in 0..<(points.count - 1) {
            let a = points[index]
            let b = points[index + 1]
            let aBase = SIMD2(a.x, baselineY)
            let bBase = SIMD2(b.x, baselineY)
            vertices.append(GPUVertex(position: aBase, uv: .zero, color: bottom))
            vertices.append(GPUVertex(position: a, uv: .zero, color: top))
            vertices.append(GPUVertex(position: b, uv: .zero, color: top))
            vertices.append(GPUVertex(position: aBase, uv: .zero, color: bottom))
            vertices.append(GPUVertex(position: b, uv: .zero, color: top))
            vertices.append(GPUVertex(position: bBase, uv: .zero, color: bottom))
        }
    }

    private func appendRibbonFill(_ vertices: inout [GPUVertex], upper: [SIMD2<Float>], lower: [SIMD2<Float>], color: SIMD4<Float>) {
        guard upper.count == lower.count, upper.count > 1 else { return }
        for index in 0..<(upper.count - 1) {
            vertices.append(contentsOf: [
                GPUVertex(position: lower[index], uv: .zero, color: color),
                GPUVertex(position: upper[index], uv: .zero, color: color),
                GPUVertex(position: upper[index + 1], uv: .zero, color: color),
                GPUVertex(position: lower[index], uv: .zero, color: color),
                GPUVertex(position: upper[index + 1], uv: .zero, color: color),
                GPUVertex(position: lower[index + 1], uv: .zero, color: color)
            ])
        }
    }

    private func appendPetal(_ vertices: inout [GPUVertex], inner: SIMD2<Float>, left: SIMD2<Float>, tip: SIMD2<Float>, right: SIMD2<Float>, color: SIMD4<Float>) {
        vertices.append(contentsOf: [
            GPUVertex(position: inner, uv: .zero, color: color),
            GPUVertex(position: left, uv: .zero, color: color),
            GPUVertex(position: tip, uv: .zero, color: color),
            GPUVertex(position: inner, uv: .zero, color: color),
            GPUVertex(position: tip, uv: .zero, color: color),
            GPUVertex(position: right, uv: .zero, color: color)
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

    private func quad(minX: Float, minY: Float, maxX: Float, maxY: Float, colors: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)) -> [GPUVertex] {
        [
            GPUVertex(position: SIMD2(minX, minY), uv: SIMD2(0, 0), color: colors.0),
            GPUVertex(position: SIMD2(maxX, minY), uv: SIMD2(1, 0), color: colors.1),
            GPUVertex(position: SIMD2(maxX, maxY), uv: SIMD2(1, 1), color: colors.2),
            GPUVertex(position: SIMD2(minX, minY), uv: SIMD2(0, 0), color: colors.0),
            GPUVertex(position: SIMD2(maxX, maxY), uv: SIMD2(1, 1), color: colors.2),
            GPUVertex(position: SIMD2(minX, maxY), uv: SIMD2(0, 1), color: colors.3)
        ]
    }

    private func gpuColor(_ color: CGColor, alpha: CGFloat? = nil) -> SIMD4<Float> {
        let rgba = VisualPalette.rgba(color)
        let a = Float(alpha ?? rgba.3)
        return SIMD4(Float(rgba.0) * a, Float(rgba.1) * a, Float(rgba.2) * a, a)
    }

    private func smooth(_ values: [Float], amount: Double) -> [Float] {
        guard values.count > 2 else { return values }
        let radius = amount > 0.72 ? 2 : (amount > 0.32 ? 1 : 0)
        guard radius > 0 else { return values }
        return values.indices.map { index in
            let lower = max(0, index - radius)
            let upper = min(values.count - 1, index + radius)
            var total: Float = 0
            for source in lower...upper { total += values[source] }
            return total / Float(upper - lower + 1)
        }
    }

    private func pseudo(_ value: CGFloat) -> CGFloat {
        let raw = sin(value * 12.9898) * 43_758.5453
        return raw - floor(raw)
    }
}
