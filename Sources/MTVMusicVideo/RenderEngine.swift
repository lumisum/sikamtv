import AppKit
import CoreImage
import CoreText
import CoreVideo
import Foundation
import Metal
import simd

final class RenderEngine {
    private struct BackgroundCacheKey: Hashable {
        let identifier: String
        let blur: Int
        let saturation: Int
        let width: Int
        let height: Int
    }

    private struct LyricLuminanceCacheKey: Hashable {
        let identifier: String
        let aspectBucket: Int
        let positionBucket: Int
    }

    private struct LyricLuminanceSample {
        let average: CGFloat
        let complexity: CGFloat
        let brightFraction: CGFloat

        static let dark = LyricLuminanceSample(average: 0.08, complexity: 0.04, brightFraction: 0)

        func mixed(with other: LyricLuminanceSample, amount: CGFloat) -> LyricLuminanceSample {
            let t = min(1, max(0, amount))
            return LyricLuminanceSample(
                average: average + (other.average - average) * t,
                complexity: complexity + (other.complexity - complexity) * t,
                brightFraction: brightFraction + (other.brightFraction - brightFraction) * t
            )
        }
    }

    private struct LyricContrastProfile {
        let scrimAlpha: CGFloat
        let outlineAlpha: CGFloat
        let outlineRadius: CGFloat
        let glowFactor: CGFloat
        let inactiveOpacityBoost: CGFloat
    }

    private let metal: MetalRenderer
    private let visualizerEngine = VisualizerEngine()
    private var backgroundCache: [BackgroundCacheKey: MTLTexture] = [:]
    private var lyricLuminanceCache: [LyricLuminanceCacheKey: LyricLuminanceSample] = [:]
    private let blurFilter = CIFilter(name: "CIGaussianBlur")
    private let colorFilter = CIFilter(name: "CIColorControls")
    private var lyricTexture: MTLTexture?

    init() {
        guard let metal = MetalRenderer() else {
            fatalError("Metal is required to render SikaMTV frames")
        }
        self.metal = metal
    }

    func render(
        size: CGSize,
        time: Double,
        settings: RenderSettings,
        background: CGImage?,
        backgroundDuration: Double,
        backgroundIdentifier: String? = nil,
        nextBackground: CGImage? = nil,
        nextBackgroundDuration: Double = 0,
        nextBackgroundIdentifier: String? = nil,
        backgroundTimeline: BackgroundTimelineState? = nil,
        lyrics: [LRCLine],
        analysis: AudioAnalysis?,
        fontName: String
    ) -> CGImage? {
        guard let texture = metal.previewTexture(size: size) else { return nil }
        render(
            to: texture,
            size: size,
            time: time,
            settings: settings,
            background: background,
            backgroundDuration: backgroundDuration,
            backgroundIdentifier: backgroundIdentifier,
            nextBackground: nextBackground,
            nextBackgroundDuration: nextBackgroundDuration,
            nextBackgroundIdentifier: nextBackgroundIdentifier,
            backgroundTimeline: backgroundTimeline,
            lyrics: lyrics,
            analysis: analysis,
            fontName: fontName
        )
        return metal.makeCGImage(from: texture)
    }

    func render(
        into pixelBuffer: CVPixelBuffer,
        size: CGSize,
        time: Double,
        settings: RenderSettings,
        background: CGImage?,
        backgroundDuration: Double,
        backgroundIdentifier: String? = nil,
        nextBackground: CGImage? = nil,
        nextBackgroundDuration: Double = 0,
        nextBackgroundIdentifier: String? = nil,
        backgroundTimeline: BackgroundTimelineState? = nil,
        lyrics: [LRCLine],
        analysis: AudioAnalysis?,
        fontName: String
    ) -> Bool {
        let prepared = prepareFrame(
            size: size,
            time: time,
            settings: settings,
            background: background,
            backgroundDuration: backgroundDuration,
            backgroundIdentifier: backgroundIdentifier,
            nextBackground: nextBackground,
            nextBackgroundDuration: nextBackgroundDuration,
            nextBackgroundIdentifier: nextBackgroundIdentifier,
            backgroundTimeline: backgroundTimeline,
            lyrics: lyrics,
            analysis: analysis,
            fontName: fontName
        )
        return metal.renderToPixelBuffer(
            pixelBuffer,
            size: size,
            backgrounds: prepared.backgrounds,
            placeholder: prepared.placeholder,
            darkness: prepared.darkness,
            vignetteAlpha: prepared.vignetteAlpha,
            accentWash: prepared.accentWash,
            mesh: prepared.mesh,
            lyrics: prepared.lyrics
        )
    }

    private func render(
        to texture: MTLTexture,
        size: CGSize,
        time: Double,
        settings: RenderSettings,
        background: CGImage?,
        backgroundDuration: Double,
        backgroundIdentifier: String?,
        nextBackground: CGImage?,
        nextBackgroundDuration: Double,
        nextBackgroundIdentifier: String?,
        backgroundTimeline: BackgroundTimelineState?,
        lyrics: [LRCLine],
        analysis: AudioAnalysis?,
        fontName: String
    ) {
        let prepared = prepareFrame(
            size: size,
            time: time,
            settings: settings,
            background: background,
            backgroundDuration: backgroundDuration,
            backgroundIdentifier: backgroundIdentifier,
            nextBackground: nextBackground,
            nextBackgroundDuration: nextBackgroundDuration,
            nextBackgroundIdentifier: nextBackgroundIdentifier,
            backgroundTimeline: backgroundTimeline,
            lyrics: lyrics,
            analysis: analysis,
            fontName: fontName
        )
        metal.render(
            to: texture,
            size: size,
            backgrounds: prepared.backgrounds,
            placeholder: prepared.placeholder,
            darkness: prepared.darkness,
            vignetteAlpha: prepared.vignetteAlpha,
            accentWash: prepared.accentWash,
            mesh: prepared.mesh,
            lyrics: prepared.lyrics
        )
    }

    private struct PreparedFrame {
        let backgrounds: [MetalRenderer.TextureLayer]
        let placeholder: [GPUVertex]
        let darkness: Float
        let vignetteAlpha: Float
        let accentWash: SIMD4<Float>
        let mesh: VisualizerMesh
        let lyrics: MetalRenderer.TextureLayer?
    }

    private func prepareFrame(
        size: CGSize,
        time: Double,
        settings: RenderSettings,
        background: CGImage?,
        backgroundDuration: Double,
        backgroundIdentifier: String?,
        nextBackground: CGImage?,
        nextBackgroundDuration: Double,
        nextBackgroundIdentifier: String?,
        backgroundTimeline: BackgroundTimelineState?,
        lyrics: [LRCLine],
        analysis: AudioAnalysis?,
        fontName: String
    ) -> PreparedFrame {
        var layers: [MetalRenderer.TextureLayer] = []
        var placeholder: [GPUVertex] = []
        if let background {
            let state = backgroundTimeline ?? BackgroundTimelineState(currentIndex: 0, nextIndex: nil, currentLocalTime: time, nextLocalTime: 0, segmentDuration: max(time, 300), transitionProgress: 0)
            let progress = CGFloat(min(1, max(0, state.transitionProgress)))
            if let nextBackground, state.nextIndex != nil {
                let transition: BackgroundTransition = state.nextIndex == state.currentIndex ? .crossfade : settings.backgroundTransition
                switch transition {
                case .crossfade:
                    appendBackgroundLayer(&layers, image: background, identifier: backgroundIdentifier, mediaDuration: backgroundDuration, localTime: state.currentLocalTime, segmentDuration: state.segmentDuration, alpha: 1, offsetX: 0, extraZoom: 1, size: size, settings: settings)
                    appendBackgroundLayer(&layers, image: nextBackground, identifier: nextBackgroundIdentifier, mediaDuration: nextBackgroundDuration, localTime: state.nextLocalTime, segmentDuration: state.segmentDuration, alpha: progress, offsetX: 0, extraZoom: 1, size: size, settings: settings)
                case .slide:
                    appendBackgroundLayer(&layers, image: background, identifier: backgroundIdentifier, mediaDuration: backgroundDuration, localTime: state.currentLocalTime, segmentDuration: state.segmentDuration, alpha: 1, offsetX: -progress * size.width, extraZoom: 1, size: size, settings: settings)
                    appendBackgroundLayer(&layers, image: nextBackground, identifier: nextBackgroundIdentifier, mediaDuration: nextBackgroundDuration, localTime: state.nextLocalTime, segmentDuration: state.segmentDuration, alpha: 1, offsetX: (1 - progress) * size.width, extraZoom: 1, size: size, settings: settings)
                case .zoom:
                    appendBackgroundLayer(&layers, image: background, identifier: backgroundIdentifier, mediaDuration: backgroundDuration, localTime: state.currentLocalTime, segmentDuration: state.segmentDuration, alpha: 1, offsetX: 0, extraZoom: 1 + progress * 0.08, size: size, settings: settings)
                    appendBackgroundLayer(&layers, image: nextBackground, identifier: nextBackgroundIdentifier, mediaDuration: nextBackgroundDuration, localTime: state.nextLocalTime, segmentDuration: state.segmentDuration, alpha: progress, offsetX: 0, extraZoom: 1.08 - progress * 0.08, size: size, settings: settings)
                case .none:
                    appendBackgroundLayer(&layers, image: nextBackground, identifier: nextBackgroundIdentifier, mediaDuration: nextBackgroundDuration, localTime: state.nextLocalTime, segmentDuration: state.segmentDuration, alpha: 1, offsetX: 0, extraZoom: 1, size: size, settings: settings)
                }
            } else {
                appendBackgroundLayer(&layers, image: background, identifier: backgroundIdentifier, mediaDuration: backgroundDuration, localTime: state.currentLocalTime, segmentDuration: state.segmentDuration, alpha: 1, offsetX: 0, extraZoom: 1, size: size, settings: settings)
            }
        } else {
            placeholder = visualizerEngine.placeholder(size: size, time: time, palette: settings.template.palette)
        }

        let features = analysis?.frame(at: time) ?? .silent
        let mesh = visualizerEngine.mesh(
            kind: settings.visualizer,
            size: size,
            features: features,
            settings: settings,
            time: time,
            template: settings.template,
            staticBackground: background != nil && backgroundDuration <= 0
        )
        let accent = VisualPalette.rgba(settings.template.palette.accent)
        let breath = 0.92 + sin(time * 0.27) * 0.08 + Double(features.loudness) * 0.08
        let washAlpha = Float((settings.template == .minimal ? 0.025 : 0.055) * breath)
        let lyricsLayer: MetalRenderer.TextureLayer?
        if LRCParser.currentIndex(at: time, in: lyrics) != nil {
            let lyricContrast = makeLyricContrastProfile(
                background: background,
                backgroundIdentifier: backgroundIdentifier,
                nextBackground: nextBackground,
                nextBackgroundIdentifier: nextBackgroundIdentifier,
                transitionProgress: backgroundTimeline?.transitionProgress ?? 0,
                size: size,
                settings: settings
            )
            lyricsLayer = makeLyricsLayer(lyrics, size: size, time: time, settings: settings, fontName: fontName, features: features, contrast: lyricContrast)
        } else {
            lyricsLayer = nil
        }
        return PreparedFrame(
            backgrounds: layers,
            placeholder: placeholder,
            darkness: Float(settings.darkness),
            vignetteAlpha: settings.template == .cinema ? 0.70 : 0.50,
            accentWash: SIMD4(Float(accent.0), Float(accent.1), Float(accent.2), washAlpha),
            mesh: mesh,
            lyrics: lyricsLayer
        )
    }

    private func appendBackgroundLayer(
        _ layers: inout [MetalRenderer.TextureLayer],
        image: CGImage,
        identifier: String?,
        mediaDuration: Double,
        localTime: Double,
        segmentDuration: Double,
        alpha: CGFloat,
        offsetX: CGFloat,
        extraZoom: CGFloat,
        size: CGSize,
        settings: RenderSettings
    ) {
        guard let texture = filteredBackground(image, identifier: identifier, mediaDuration: mediaDuration, targetSize: size, settings: settings) else { return }
        let isStatic = mediaDuration <= 0
        let zoomProgress = isStatic ? min(1, max(0, localTime / max(0.001, segmentDuration))) : 0
        let breathingZoom = isStatic ? 0.012 * (0.5 + 0.5 * sin(localTime * 0.16)) : 0
        let baseZoom = isStatic ? 1.018 + 0.052 * zoomProgress + breathingZoom : 1
        let zoom = CGFloat(baseZoom) * extraZoom
        let container = CGRect(x: offsetX, y: 0, width: size.width, height: size.height)
        var imageRect = aspectFillRect(imageSize: CGSize(width: texture.width, height: texture.height), in: container, zoom: zoom)
        if isStatic {
            let availableX = max(0, (imageRect.width - container.width) * 0.38)
            let availableY = max(0, (imageRect.height - container.height) * 0.38)
            imageRect.origin.x += sin(localTime * 0.055) * availableX
            imageRect.origin.y += cos(localTime * 0.043) * availableY
        }
        layers.append(MetalRenderer.TextureLayer(texture: texture, rect: imageRect, alpha: Float(alpha)))
    }

    private func filteredBackground(_ image: CGImage, identifier: String?, mediaDuration: Double, targetSize: CGSize, settings: RenderSettings) -> MTLTexture? {
        if mediaDuration <= 0, let identifier {
            let key = BackgroundCacheKey(identifier: identifier, blur: Int(settings.blur * 10), saturation: Int(settings.saturation * 100), width: Int(targetSize.width), height: Int(targetSize.height))
            if let cached = backgroundCache[key] { return cached }
            guard let texture = makeFilteredTexture(image, targetSize: targetSize, settings: settings) else { return nil }
            if backgroundCache.count > 24 { backgroundCache.removeAll(keepingCapacity: true) }
            backgroundCache[key] = texture
            return texture
        }
        return makeFilteredTexture(image, targetSize: targetSize, settings: settings)
    }

    private func makeFilteredTexture(_ image: CGImage, targetSize: CGSize, settings: RenderSettings) -> MTLTexture? {
        var ciImage = CIImage(cgImage: image)
        let sourceSize = CGSize(width: image.width, height: image.height)
        let downsampleScale = min(1, max(targetSize.width / max(1, sourceSize.width), targetSize.height / max(1, sourceSize.height)) * 1.06)
        if downsampleScale < 0.999 {
            ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: downsampleScale, y: downsampleScale))
        }
        let renderScale = targetSize.width / max(1, settings.aspectRatio.size1080.width)
        let blurWorkingScale: CGFloat = settings.blur > 0 ? 0.5 : 1
        if blurWorkingScale < 0.999 {
            ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: blurWorkingScale, y: blurWorkingScale))
        }
        if settings.blur > 0, let filter = blurFilter {
            filter.setValue(ciImage, forKey: kCIInputImageKey)
            filter.setValue(settings.blur * renderScale * blurWorkingScale, forKey: kCIInputRadiusKey)
            ciImage = filter.outputImage?.cropped(to: ciImage.extent) ?? ciImage
        }
        if let color = colorFilter {
            color.setValue(ciImage, forKey: kCIInputImageKey)
            color.setValue(settings.saturation, forKey: kCIInputSaturationKey)
            color.setValue(0, forKey: kCIInputBrightnessKey)
            color.setValue(1, forKey: kCIInputContrastKey)
            ciImage = color.outputImage?.cropped(to: ciImage.extent) ?? ciImage
        }
        let extent = ciImage.extent.standardized
        let width = max(1, Int(extent.width.rounded(.up)))
        let height = max(1, Int(extent.height.rounded(.up)))
        guard let texture = metal.makeTexture(width: width, height: height) else { return nil }
        metal.renderCIImage(ciImage.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)), to: texture)
        return texture
    }

    private func makeLyricContrastProfile(
        background: CGImage?,
        backgroundIdentifier: String?,
        nextBackground: CGImage?,
        nextBackgroundIdentifier: String?,
        transitionProgress: Double,
        size: CGSize,
        settings: RenderSettings
    ) -> LyricContrastProfile {
        var sample = lyricLuminanceSample(
            for: background,
            identifier: backgroundIdentifier,
            size: size,
            positionY: CGFloat(settings.lyricPositionY)
        )
        if let nextBackground {
            let next = lyricLuminanceSample(
                for: nextBackground,
                identifier: nextBackgroundIdentifier,
                size: size,
                positionY: CGFloat(settings.lyricPositionY)
            )
            sample = sample.mixed(with: next, amount: CGFloat(transitionProgress))
        }

        let effectiveLuminance = sample.average * CGFloat(max(0, 1 - settings.darkness))
        let brightness = smoothstep(0.26, 0.76, effectiveLuminance)
        let complexity = min(1, sample.complexity * max(0.5, 1 - CGFloat(settings.blur) / 72))
        let risk = min(1, brightness * 0.70 + complexity * 0.22 + sample.brightFraction * 0.22)
        return LyricContrastProfile(
            scrimAlpha: 0.025 + risk * 0.30,
            outlineAlpha: 0.34 + risk * 0.58,
            outlineRadius: 1.15 + risk * 1.75,
            glowFactor: 1 - risk * 0.42,
            inactiveOpacityBoost: risk * 0.18
        )
    }

    private func lyricLuminanceSample(
        for image: CGImage?,
        identifier: String?,
        size: CGSize,
        positionY: CGFloat
    ) -> LyricLuminanceSample {
        guard let image else { return .dark }
        let key = identifier.map {
            LyricLuminanceCacheKey(
                identifier: $0,
                aspectBucket: Int((size.width / max(1, size.height) * 100).rounded()),
                positionBucket: Int((positionY * 20).rounded())
            )
        }
        if let key, let cached = lyricLuminanceCache[key] { return cached }

        let sampleWidth = 24
        let sampleHeight = 18
        var pixels = [UInt8](repeating: 0, count: sampleWidth * sampleHeight * 4)
        guard let context = CGContext(
            data: &pixels,
            width: sampleWidth,
            height: sampleHeight,
            bitsPerComponent: 8,
            bytesPerRow: sampleWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return .dark }
        context.interpolationQuality = .low
        let destination = aspectFillRect(
            imageSize: CGSize(width: image.width, height: image.height),
            in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight),
            zoom: 1
        )
        context.draw(image, in: destination)

        let centerRow = min(sampleHeight - 1, max(0, Int((positionY * CGFloat(sampleHeight - 1)).rounded())))
        let rowRadius = 4
        let firstRow = max(0, centerRow - rowRadius)
        let lastRow = min(sampleHeight - 1, centerRow + rowRadius)
        var luminances: [CGFloat] = []
        luminances.reserveCapacity(sampleWidth * (lastRow - firstRow + 1))
        for y in firstRow...lastRow {
            for x in 0..<sampleWidth {
                let offset = (y * sampleWidth + x) * 4
                let red = CGFloat(pixels[offset]) / 255
                let green = CGFloat(pixels[offset + 1]) / 255
                let blue = CGFloat(pixels[offset + 2]) / 255
                luminances.append(red * 0.2126 + green * 0.7152 + blue * 0.0722)
            }
        }
        guard !luminances.isEmpty else { return .dark }
        let average = luminances.reduce(0, +) / CGFloat(luminances.count)
        let variance = luminances.reduce(CGFloat.zero) { $0 + pow($1 - average, 2) } / CGFloat(luminances.count)
        let brightFraction = CGFloat(luminances.filter { $0 > 0.68 }.count) / CGFloat(luminances.count)
        let sample = LyricLuminanceSample(
            average: average,
            complexity: min(1, sqrt(variance) * 2.25),
            brightFraction: brightFraction
        )
        if let key {
            if lyricLuminanceCache.count > 48 { lyricLuminanceCache.removeAll(keepingCapacity: true) }
            lyricLuminanceCache[key] = sample
        }
        return sample
    }

    private func makeLyricsLayer(_ lines: [LRCLine], size: CGSize, time: Double, settings: RenderSettings, fontName: String, features: AudioFrameFeatures, contrast: LyricContrastProfile) -> MetalRenderer.TextureLayer? {
        guard LRCParser.currentIndex(at: time, in: lines) != nil else { return nil }
        let renderScale = size.width / max(1, settings.aspectRatio.size1080.width)
        let fontSize = CGFloat(settings.lyricSize) * renderScale
        let lineHeight = fontSize * CGFloat(settings.lyricLineSpacing)
        let centerY = size.height * CGFloat(settings.lyricPositionY)
        let availableWidth = size.width * CGFloat(settings.lyricWidth)
        let left = (size.width - availableWidth) / 2
        let clip = CGRect(x: left - fontSize * 2.2, y: centerY - lineHeight * 2.7, width: availableWidth + fontSize * 4.4, height: lineHeight * 5.4)
        let width = max(1, Int(clip.width.rounded(.up)))
        let height = max(1, Int(clip.height.rounded(.up)))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: -clip.minX, y: -clip.minY)
        drawLyrics(lines, in: context, size: size, time: time, settings: settings, fontName: fontName, features: features, contrast: contrast)
        guard let image = context.makeImage() else { return nil }
        if lyricTexture?.width != width || lyricTexture?.height != height {
            lyricTexture = metal.makeTexture(width: width, height: height)
        }
        guard let lyricTexture else { return nil }
        metal.renderCIImage(CIImage(cgImage: image), to: lyricTexture)
        return MetalRenderer.TextureLayer(texture: lyricTexture, rect: clip, alpha: 1)
    }

    private func aspectFillRect(imageSize: CGSize, in container: CGRect, zoom: CGFloat) -> CGRect {
        let scale = max(container.width / imageSize.width, container.height / imageSize.height) * zoom
        let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: container.midX - fitted.width / 2, y: container.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }

    private func drawLyrics(_ lines: [LRCLine], in context: CGContext, size: CGSize, time: Double, settings: RenderSettings, fontName: String, features: AudioFrameFeatures, contrast: LyricContrastProfile) {
        guard let current = LRCParser.currentIndex(at: time, in: lines) else { return }
        let palette = settings.template.palette
        let renderScale = size.width / max(1, settings.aspectRatio.size1080.width)
        let fontSize = CGFloat(settings.lyricSize) * renderScale
        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        let lineHeight = fontSize * CGFloat(settings.lyricLineSpacing)
        let centerY = size.height * CGFloat(settings.lyricPositionY)
        let availableWidth = size.width * CGFloat(settings.lyricWidth)
        let left = (size.width - availableWidth) / 2
        let elapsed = max(0, time - lines[current].time)
        let rawProgress = settings.lyricAnimationDuration <= 0 ? 1 : min(1, elapsed / settings.lyricAnimationDuration)
        let progress = easeOutCubic(CGFloat(rawProgress))
        let nextTime = current + 1 < lines.count ? lines[current + 1].time : time + max(settings.lyricAnimationDuration, 1.4)
        let lineHold = max(0.12, nextTime - lines[current].time)
        let karaokeProgress = min(1, max(0, elapsed / lineHold))
        let beat = CGFloat(features.beat)

        drawLyricScrim(
            center: CGPoint(x: size.width / 2, y: centerY),
            width: min(size.width * 0.96, availableWidth + fontSize * 4),
            height: lineHeight * 3.65,
            alpha: contrast.scrimAlpha,
            in: context
        )

        for index in max(0, current - 1)...min(lines.count - 1, current + 1) {
            let relation = index - current
            var y = centerY - CGFloat(relation) * lineHeight
            var alpha = relation == 0 ? CGFloat(1) : CGFloat(settings.lyricInactiveOpacity)
            if relation != 0 {
                alpha = min(0.76, alpha + contrast.inactiveOpacityBoost)
            }
            var scale: CGFloat = 1
            var glowBoost: CGFloat = 1
            var karaoke: CGFloat? = nil
            switch settings.lyricAnimation {
            case .scroll:
                y -= (1 - progress) * lineHeight
                if relation == 0 { alpha = 0.42 + progress * 0.58 }
            case .fade:
                if relation == 0 { alpha = 0.18 + progress * 0.82 }
            case .scale:
                if relation == 0 {
                    alpha = 0.28 + progress * 0.72
                    scale = 0.86 + progress * 0.16 + beat * 0.03
                    glowBoost = 0.85 + progress * 0.35
                }
            case .karaoke:
                if relation == 0 {
                    alpha = 0.55 + progress * 0.45
                    karaoke = karaokeProgress
                    glowBoost = 0.9 + beat * 0.35
                }
            case .bloom:
                if relation == 0 {
                    alpha = 0.22 + progress * 0.78
                    scale = 0.92 + progress * 0.10 + beat * 0.04
                    y += (1 - progress) * fontSize * 0.18
                    glowBoost = 0.7 + progress * 0.85 + beat * 0.45
                }
            case .none:
                break
            }
            let isCurrent = relation == 0
            let fillColor: CGColor
            if isCurrent {
                fillColor = VisualPalette.mix(CGColor(gray: 1, alpha: 1), palette.lyric, 0.42).copy(alpha: alpha) ?? palette.lyric
            } else {
                fillColor = VisualPalette.mix(CGColor(gray: 1, alpha: 1), palette.secondary, 0.36).copy(alpha: alpha) ?? palette.secondary
            }
            drawText(
                lines[index].text,
                centerY: y,
                left: left,
                width: availableWidth,
                font: font,
                color: fillColor,
                highlightColor: VisualPalette.mix(palette.highlight, CGColor(gray: 1, alpha: 1), 0.35),
                glowColor: palette.accent,
                secondaryGlowColor: palette.secondary,
                alignment: settings.lyricAlignment,
                scale: scale,
                highlight: isCurrent,
                glow: CGFloat(settings.lyricGlow) * 36 * renderScale * glowBoost * contrast.glowFactor,
                outlineAlpha: contrast.outlineAlpha,
                outlineRadius: contrast.outlineRadius * renderScale,
                karaokeProgress: karaoke,
                beat: beat,
                in: context
            )
        }
    }

    private func drawText(
        _ text: String,
        centerY: CGFloat,
        left: CGFloat,
        width: CGFloat,
        font: CTFont,
        color: CGColor,
        highlightColor: CGColor,
        glowColor: CGColor,
        secondaryGlowColor: CGColor,
        alignment: LyricAlignment,
        scale: CGFloat,
        highlight: Bool,
        glow: CGFloat,
        outlineAlpha: CGFloat,
        outlineRadius: CGFloat,
        karaokeProgress: CGFloat?,
        beat: CGFloat,
        in context: CGContext
    ) {
        let content = text.isEmpty ? "♪" : text
        var activeFont = font
        var attributed = NSAttributedString(string: content, attributes: [.font: activeFont, .foregroundColor: color])
        var line = CTLineCreateWithAttributedString(attributed)
        var bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        if bounds.width > width, bounds.width > 0 {
            let fittedSize = CTFontGetSize(font) * max(0.66, width / bounds.width)
            activeFont = CTFontCreateCopyWithAttributes(font, fittedSize, nil, nil)
            attributed = NSAttributedString(string: content, attributes: [.font: activeFont, .foregroundColor: color])
            line = CTLineCreateWithAttributedString(attributed)
            bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        }
        let x: CGFloat
        switch alignment {
        case .leading: x = left
        case .center: x = left + (width - bounds.width) / 2
        case .trailing: x = left + width - bounds.width
        }
        let anchorX: CGFloat
        switch alignment {
        case .leading: anchorX = x
        case .center: anchorX = x + bounds.width / 2
        case .trailing: anchorX = x + bounds.width
        }
        let textY = centerY - bounds.height / 2
        context.saveGState()
        if scale != 1 {
            context.translateBy(x: anchorX, y: centerY)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -anchorX, y: -centerY)
        }

        if highlight, glow > 0 {
            context.saveGState()
            context.setBlendMode(.plusLighter)
            if let inner = VisualPalette.mix(glowColor, secondaryGlowColor, 0.4).copy(alpha: 0.14 + beat * 0.10),
               let outer = glowColor.copy(alpha: 0),
               let blob = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [inner, outer] as CFArray, locations: [0, 1]) {
                context.drawRadialGradient(
                    blob,
                    startCenter: CGPoint(x: anchorX, y: centerY),
                    startRadius: 0,
                    endCenter: CGPoint(x: anchorX, y: centerY),
                    endRadius: max(bounds.width * 0.42, glow * 1.6),
                    options: []
                )
            }
            context.restoreGState()
        }

        let sourceAlpha = color.alpha
        let contour = NSAttributedString(
            string: content,
            attributes: [
                .font: activeFont,
                .foregroundColor: CGColor(gray: 0.005, alpha: outlineAlpha * sourceAlpha)
            ]
        )
        let contourLine = CTLineCreateWithAttributedString(contour)
        let radius = max(0.75, outlineRadius)
        let diagonal = radius * 0.72
        let offsets = [
            CGPoint(x: -radius, y: 0), CGPoint(x: radius, y: 0),
            CGPoint(x: 0, y: -radius), CGPoint(x: 0, y: radius),
            CGPoint(x: -diagonal, y: -diagonal), CGPoint(x: diagonal, y: -diagonal),
            CGPoint(x: -diagonal, y: diagonal), CGPoint(x: diagonal, y: diagonal)
        ]
        context.saveGState()
        context.setShadow(offset: .zero, blur: radius * 1.35, color: CGColor(gray: 0, alpha: outlineAlpha * 0.72 * sourceAlpha))
        for offset in offsets {
            context.textPosition = CGPoint(x: x + offset.x, y: textY + offset.y)
            CTLineDraw(contourLine, context)
        }
        context.restoreGState()

        context.textPosition = CGPoint(x: x, y: textY)
        if highlight, glow > 0 {
            context.saveGState()
            context.setBlendMode(.plusLighter)
            let colorOffset = max(0.6, min(2.4, glow * 0.045))
            let chromatic = NSAttributedString(
                string: content,
                attributes: [
                    .font: activeFont,
                    .foregroundColor: secondaryGlowColor.copy(alpha: 0.15) ?? secondaryGlowColor
                ]
            )
            let chromaticLine = CTLineCreateWithAttributedString(chromatic)
            context.setShadow(
                offset: CGSize(width: -colorOffset, height: colorOffset * 0.45),
                blur: min(30, glow * 0.72),
                color: secondaryGlowColor.copy(alpha: 0.30)
            )
            context.textPosition = CGPoint(x: x + colorOffset, y: textY)
            CTLineDraw(chromaticLine, context)
            context.restoreGState()

            context.textPosition = CGPoint(x: x, y: textY)
            context.setShadow(offset: .zero, blur: min(22, glow * 0.42), color: glowColor.copy(alpha: 0.40))
        }
        CTLineDraw(line, context)
        context.setShadow(offset: .zero, blur: 0, color: nil)

        if highlight, let karaokeProgress {
            let utf16Count = (content as NSString).length
            let shown = min(utf16Count, max(0, Int(ceil(Double(karaokeProgress) * Double(utf16Count)))))
            let wipe = CTLineGetOffsetForStringIndex(line, shown, nil)
            context.saveGState()
            context.clip(to: CGRect(x: x - 2, y: textY - bounds.height, width: max(0, wipe + 3), height: bounds.height * 3))
            let bright = NSAttributedString(string: content, attributes: [.font: activeFont, .foregroundColor: highlightColor])
            let brightLine = CTLineCreateWithAttributedString(bright)
            context.setBlendMode(.plusLighter)
            context.textPosition = CGPoint(x: x, y: textY)
            CTLineDraw(brightLine, context)
            context.restoreGState()
        }

        if highlight {
            let underlineWidth = max(18, bounds.width * (karaokeProgress ?? (0.42 + beat * 0.2)))
            let underlineX: CGFloat
            switch alignment {
            case .leading: underlineX = x
            case .center: underlineX = anchorX - underlineWidth / 2
            case .trailing: underlineX = x + bounds.width - underlineWidth
            }
            context.setBlendMode(.plusLighter)
            context.setFillColor(glowColor.copy(alpha: 0.20 + beat * 0.16) ?? glowColor)
            context.fill(CGRect(x: underlineX, y: textY - glow * 0.08, width: underlineWidth, height: max(1.6, glow * 0.045)))
        }
        context.restoreGState()
    }

    private func drawLyricScrim(center: CGPoint, width: CGFloat, height: CGFloat, alpha: CGFloat, in context: CGContext) {
        guard alpha > 0.001, width > 0, height > 0 else { return }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [
                CGColor(gray: 0, alpha: alpha),
                CGColor(gray: 0, alpha: alpha * 0.62),
                CGColor(gray: 0, alpha: 0)
            ] as CFArray,
            locations: [0, 0.52, 1]
        ) else { return }
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.scaleBy(x: 1, y: height / max(1, width))
        context.drawRadialGradient(
            gradient,
            startCenter: .zero,
            startRadius: 0,
            endCenter: .zero,
            endRadius: width / 2,
            options: []
        )
        context.restoreGState()
    }

    private func smoothstep(_ lower: CGFloat, _ upper: CGFloat, _ value: CGFloat) -> CGFloat {
        let t = min(1, max(0, (value - lower) / max(0.0001, upper - lower)))
        return t * t * (3 - 2 * t)
    }

    private func easeOutCubic(_ value: CGFloat) -> CGFloat {
        1 - pow(1 - value, 3)
    }
}
