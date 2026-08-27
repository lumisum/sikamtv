import CoreGraphics
import Foundation

/// Audio-reactive scene renderer. Motion is primarily driven by analyzed waveform,
/// frequency envelopes and beat pulses; time only provides slow atmospheric drift.
struct VisualizerEngine {
    func draw(
        kind: VisualizerKind,
        in context: CGContext,
        size: CGSize,
        features: AudioFrameFeatures,
        settings: RenderSettings,
        color: CGColor,
        time: Double,
        template: VisualTemplate
    ) {
        guard size.width > 0, size.height > 0 else { return }
        let spectrum = smooth(features.spectrum, amount: settings.visualizerSmoothing)
        let frame = AudioFrameFeatures(
            amplitude: features.amplitude,
            loudness: features.loudness,
            bass: features.bass,
            mid: features.mid,
            high: features.high,
            beat: features.beat,
            spectrum: spectrum,
            waveform: features.waveform
        )
        let center = CGPoint(x: size.width * 0.5, y: size.height * settings.visualizerPositionY)
        let renderScale = size.width / max(1, settings.aspectRatio.size1080.width)

        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        drawAura(in: context, center: center, size: size, features: frame, settings: settings, color: color)
        switch (template, kind) {
        case (.zen, .ripple), (.cinema, .ripple):
            drawZenRipple(in: context, center: center, size: size, features: frame, settings: settings, color: color, time: time, renderScale: renderScale)
        case (.ethereal, _):
            drawEtherealFlow(in: context, center: center, size: size, features: frame, settings: settings, color: color, time: time, renderScale: renderScale)
        case (.electronic, _):
            drawElectronicSpectrum(in: context, center: center, size: size, features: frame, settings: settings, color: color, mirrored: kind == .mirror, renderScale: renderScale)
        default:
            switch kind {
            case .wave:
                drawWave(in: context, center: center, size: size, features: frame, settings: settings, color: color, renderScale: renderScale)
            case .spectrum, .mirror:
                drawElectronicSpectrum(in: context, center: center, size: size, features: frame, settings: settings, color: color, mirrored: kind == .mirror, renderScale: renderScale)
            case .circle:
                drawEnergyRing(in: context, center: center, size: size, features: frame, settings: settings, color: color, time: time, renderScale: renderScale)
            case .ripple:
                drawZenRipple(in: context, center: center, size: size, features: frame, settings: settings, color: color, time: time, renderScale: renderScale)
            }
        }
        context.restoreGState()
    }

    private func drawAura(in context: CGContext, center: CGPoint, size: CGSize, features: AudioFrameFeatures, settings: RenderSettings, color: CGColor) {
        let radius = min(size.width, size.height) * (0.18 + CGFloat(features.bass) * 0.055) * settings.visualizerScale
        guard let transparent = color.copy(alpha: 0),
              let inner = color.copy(alpha: CGFloat(settings.visualizerGlow) * (0.07 + CGFloat(features.beat) * 0.07)),
              let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [inner, transparent] as CFArray, locations: [0, 1]) else { return }
        context.saveGState()
        context.setBlendMode(.plusLighter)
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
        context.restoreGState()
    }

    private func drawWave(in context: CGContext, center: CGPoint, size: CGSize, features: AudioFrameFeatures, settings: RenderSettings, color: CGColor, renderScale: CGFloat) {
        let values = features.waveform.isEmpty ? AudioFrameFeatures.silent.waveform : features.waveform
        let width = size.width * 0.82 * settings.visualizerScale
        let height = min(size.width, size.height) * (0.055 + CGFloat(features.loudness) * 0.055) * settings.visualizerStrength
        let startX = center.x - width / 2
        context.saveGState()
        context.setBlendMode(.plusLighter)
        for layer in stride(from: 2, through: 0, by: -1) {
            let path = CGMutablePath()
            for index in values.indices {
                let x = startX + CGFloat(index) / CGFloat(max(1, values.count - 1)) * width
                let softened = (values[index] + values[max(0, index - 1)] + values[min(values.count - 1, index + 1)]) / 3
                let y = center.y + CGFloat(softened) * height * (1 - CGFloat(layer) * 0.12)
                if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            let alpha: CGFloat = layer == 0 ? 0.92 : 0.17
            context.setStrokeColor(color.copy(alpha: alpha) ?? color)
            context.setLineWidth((layer == 0 ? 2.1 : CGFloat(7 + layer * 5)) * renderScale)
            context.setShadow(offset: .zero, blur: CGFloat(settings.visualizerGlow) * 18 * renderScale, color: color.copy(alpha: 0.48))
            context.addPath(path)
            context.strokePath()
        }
        context.restoreGState()
    }

    private func drawElectronicSpectrum(in context: CGContext, center: CGPoint, size: CGSize, features: AudioFrameFeatures, settings: RenderSettings, color: CGColor, mirrored: Bool, renderScale: CGFloat) {
        let count = max(36, Int(36 + settings.visualizerDensity * 44))
        let width = size.width * 0.84 * settings.visualizerScale
        let gap = width / CGFloat(count)
        let barWidth = max(renderScale * 2, gap * 0.52)
        let baseline = center.y
        let maxHeight = min(size.height * 0.25, min(size.width, size.height) * 0.31) * settings.visualizerStrength
        let spectrum = features.spectrum
        guard !spectrum.isEmpty else { return }

        context.saveGState()
        context.setBlendMode(.plusLighter)
        context.setShadow(offset: .zero, blur: CGFloat(settings.visualizerGlow) * 18 * renderScale, color: color.copy(alpha: 0.52))
        for index in 0..<count {
            let progress = CGFloat(index) / CGFloat(max(1, count - 1))
            let sourceProgress = mirrored ? abs(progress - 0.5) * 2 : progress
            let source = min(spectrum.count - 1, Int(pow(sourceProgress, 1.38) * CGFloat(spectrum.count - 1)))
            let value = CGFloat(spectrum[source])
            let bassBoost = sourceProgress < 0.18 ? CGFloat(features.bass) * 0.20 : 0
            let height = max(2 * renderScale, pow(value + bassBoost, 1.18) * maxHeight + CGFloat(features.beat) * maxHeight * 0.045)
            let x = center.x - width / 2 + CGFloat(index) * gap + (gap - barWidth) / 2
            let rect = CGRect(x: x, y: baseline, width: barWidth, height: height)
            let bar = CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)
            context.setFillColor(color.copy(alpha: 0.38 + min(0.58, value * 0.62)) ?? color)
            context.addPath(bar)
            context.fillPath()

            let reflection = CGRect(x: x, y: baseline - height * 0.30 - renderScale, width: barWidth, height: height * 0.30)
            context.setFillColor(color.copy(alpha: 0.07 + value * 0.10) ?? color)
            context.addPath(CGPath(roundedRect: reflection, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
            context.fillPath()

            let peakY = baseline + height + max(2, 5 * renderScale)
            context.setFillColor(color.copy(alpha: 0.24 + CGFloat(features.beat) * 0.35) ?? color)
            context.fill(CGRect(x: x, y: peakY, width: barWidth, height: max(1, 1.5 * renderScale)))
        }
        context.setStrokeColor(color.copy(alpha: 0.20) ?? color)
        context.setLineWidth(max(0.8, renderScale))
        context.move(to: CGPoint(x: center.x - width / 2, y: baseline))
        context.addLine(to: CGPoint(x: center.x + width / 2, y: baseline))
        context.strokePath()
        context.restoreGState()
    }

    private func drawEnergyRing(in context: CGContext, center: CGPoint, size: CGSize, features: AudioFrameFeatures, settings: RenderSettings, color: CGColor, time: Double, renderScale: CGFloat) {
        let minimum = min(size.width, size.height)
        let radius = minimum * 0.145 * settings.visualizerScale * (1 + CGFloat(features.beat) * 0.035)
        let values = features.spectrum
        guard !values.isEmpty else { return }
        context.saveGState()
        context.setBlendMode(.plusLighter)
        for pass in stride(from: 2, through: 0, by: -1) {
            let path = CGMutablePath()
            let points = max(120, Int(120 + settings.visualizerDensity * 100))
            for index in 0...points {
                let p = CGFloat(index) / CGFloat(points)
                let angle = p * .pi * 2 - .pi / 2
                let mirrored = p <= 0.5 ? p * 2 : (1 - p) * 2
                let source = min(values.count - 1, Int(mirrored * CGFloat(values.count - 1)))
                let value = CGFloat(values[source])
                let displacement = value * minimum * 0.052 * settings.visualizerStrength
                let slowDrift = sin(angle * 3 + CGFloat(time) * 0.28) * CGFloat(features.mid) * minimum * 0.004
                let r = radius + displacement + slowDrift
                let point = CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
            context.setStrokeColor(color.copy(alpha: pass == 0 ? 0.92 : 0.10 + CGFloat(pass) * 0.04) ?? color)
            context.setLineWidth((pass == 0 ? 2.0 : CGFloat(8 + pass * 6)) * renderScale)
            context.setShadow(offset: .zero, blur: CGFloat(settings.visualizerGlow) * 22 * renderScale, color: color.copy(alpha: 0.58))
            context.addPath(path)
            context.strokePath()
        }
        drawMusicParticles(in: context, center: center, radius: radius * 1.65, size: size, features: features, settings: settings, color: color, time: time, renderScale: renderScale)
        context.restoreGState()
    }

    private func drawZenRipple(in context: CGContext, center: CGPoint, size: CGSize, features: AudioFrameFeatures, settings: RenderSettings, color: CGColor, time: Double, renderScale: CGFloat) {
        let minimum = min(size.width, size.height)
        let baseRadius = minimum * 0.105 * settings.visualizerScale
        let values = features.spectrum
        guard !values.isEmpty else { return }
        context.saveGState()
        context.setBlendMode(.plusLighter)
        context.setShadow(offset: .zero, blur: CGFloat(settings.visualizerGlow) * 20 * renderScale, color: color.copy(alpha: 0.48))

        let ringCount = max(4, Int(4 + settings.visualizerDensity * 4))
        for ring in 0..<ringCount {
            let path = CGMutablePath()
            let ringProgress = CGFloat(ring) / CGFloat(max(1, ringCount - 1))
            let phase = (CGFloat(time) * 0.14 + ringProgress).truncatingRemainder(dividingBy: 1)
            let radius = baseRadius + minimum * (0.035 + 0.035 * CGFloat(ring)) + phase * minimum * 0.018
                + CGFloat(features.bass) * minimum * 0.018 * settings.visualizerStrength
            let pointCount = 144
            for index in 0...pointCount {
                let p = CGFloat(index) / CGFloat(pointCount)
                let angle = p * .pi * 2
                let source = min(values.count - 1, Int(p * CGFloat(values.count - 1)))
                let spectral = CGFloat(values[source]) * minimum * 0.010 * settings.visualizerStrength
                let r = radius + spectral * sin(angle * 2 + CGFloat(ring))
                let point = CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r * 0.66)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
            let fade = (1 - ringProgress) * 0.24 + CGFloat(features.beat) * (1 - ringProgress) * 0.20
            context.setStrokeColor(color.copy(alpha: max(0.035, fade)) ?? color)
            context.setLineWidth((ring == 0 ? 2.0 : 1.15) * renderScale)
            context.addPath(path)
            context.strokePath()
        }

        let rays = max(56, Int(56 + settings.visualizerDensity * 48))
        for index in 0..<rays {
            let p = CGFloat(index) / CGFloat(rays)
            let angle = p * .pi * 2
            let source = min(values.count - 1, Int(p * CGFloat(values.count - 1)))
            let value = CGFloat(values[source])
            let inner = baseRadius * 0.90
            let outer = inner + minimum * (0.018 + value * 0.085 * settings.visualizerStrength + CGFloat(features.beat) * 0.012)
            context.setStrokeColor(color.copy(alpha: 0.06 + value * 0.35) ?? color)
            context.setLineWidth((0.8 + value * 1.5) * renderScale)
            context.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner * 0.66))
            context.addLine(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer * 0.66))
            context.strokePath()
        }
        drawMusicParticles(in: context, center: center, radius: baseRadius * 2.5, size: size, features: features, settings: settings, color: color, time: time, renderScale: renderScale)
        context.restoreGState()
    }

    private func drawEtherealFlow(in context: CGContext, center: CGPoint, size: CGSize, features: AudioFrameFeatures, settings: RenderSettings, color: CGColor, time: Double, renderScale: CGFloat) {
        let width = size.width * 0.72 * settings.visualizerScale
        let height = min(size.width, size.height) * 0.14 * settings.visualizerStrength
        let spectrum = features.spectrum
        guard !spectrum.isEmpty else { return }
        context.saveGState()
        context.setBlendMode(.plusLighter)
        for ribbon in 0..<5 {
            let path = CGMutablePath()
            let phase = CGFloat(ribbon) * 0.62
            for point in 0...160 {
                let p = CGFloat(point) / 160
                let source = min(spectrum.count - 1, Int(p * CGFloat(spectrum.count - 1)))
                let spectral = CGFloat(spectrum[source])
                let x = center.x - width / 2 + p * width
                let waveformIndex = min(features.waveform.count - 1, Int(p * CGFloat(max(1, features.waveform.count - 1))))
                let waveform = features.waveform.isEmpty ? 0 : CGFloat(features.waveform[waveformIndex])
                let flow = sin(p * .pi * 4.5 + CGFloat(time) * (0.22 + CGFloat(ribbon) * 0.025) + phase)
                let y = center.y + flow * height * (0.22 + spectral * 0.58) + waveform * height * 0.34 + (CGFloat(ribbon) - 2) * 5 * renderScale
                if point == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.setStrokeColor(color.copy(alpha: ribbon == 2 ? 0.58 : 0.10 + CGFloat(features.high) * 0.10) ?? color)
            context.setLineWidth((ribbon == 2 ? 2.0 : CGFloat(4 + ribbon * 2)) * renderScale)
            context.setShadow(offset: .zero, blur: CGFloat(settings.visualizerGlow) * 24 * renderScale, color: color.copy(alpha: 0.50))
            context.addPath(path)
            context.strokePath()
        }
        drawMusicParticles(in: context, center: center, radius: width * 0.48, size: size, features: features, settings: settings, color: color, time: time, renderScale: renderScale)
        context.restoreGState()
    }

    private func drawMusicParticles(in context: CGContext, center: CGPoint, radius: CGFloat, size: CGSize, features: AudioFrameFeatures, settings: RenderSettings, color: CGColor, time: Double, renderScale: CGFloat) {
        let count = max(18, Int(18 + settings.visualizerDensity * 58))
        let intensity = CGFloat(features.high * 0.62 + features.beat * 0.38)
        guard intensity > 0.025 else { return }
        context.saveGState()
        context.setBlendMode(.plusLighter)
        context.setShadow(offset: .zero, blur: CGFloat(settings.visualizerGlow) * 10 * renderScale, color: color.copy(alpha: 0.48))
        for index in 0..<count {
            let seed = CGFloat(index)
            let angle = seed * 2.399963 + CGFloat(time) * (0.025 + CGFloat(index % 5) * 0.006)
            let audioPush = 1 + CGFloat(features.beat) * (0.08 + CGFloat(index % 7) * 0.008)
            let orbit = radius * (0.25 + pseudo(seed * 4.37) * 0.75) * audioPush
            let x = center.x + cos(angle) * orbit
            let y = center.y + sin(angle * 1.13) * orbit * 0.58
            let dot = (0.8 + pseudo(seed * 8.91) * 2.6 + intensity * 1.8) * renderScale
            context.setFillColor(color.copy(alpha: 0.035 + intensity * (0.09 + pseudo(seed) * 0.18)) ?? color)
            context.fillEllipse(in: CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot))
        }
        context.restoreGState()
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
