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
        let smartBlur: Bool
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
    private let atmosphereEngine = AtmosphereEngine()
    private var backgroundCache: [BackgroundCacheKey: MTLTexture] = [:]
    private var subjectMaskTextures: [String: MTLTexture] = [:]
    private var lyricLuminanceCache: [LyricLuminanceCacheKey: LyricLuminanceSample] = [:]
    private var sceneColorCache: [String: SceneColorProfile] = [:]
    private let blurFilter = CIFilter(name: "CIGaussianBlur")
    private let colorFilter = CIFilter(name: "CIColorControls")
    private var lyricTexture: MTLTexture?
    private var introTexture: MTLTexture?

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
            title: prepared.title,
            lyrics: prepared.lyrics,
            backgroundMotion: prepared.backgroundMotion,
            postProcess: prepared.postProcess
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
            title: prepared.title,
            lyrics: prepared.lyrics,
            backgroundMotion: prepared.backgroundMotion,
            postProcess: prepared.postProcess
        )
    }

    private struct PreparedFrame {
        let backgrounds: [MetalRenderer.TextureLayer]
        let placeholder: [GPUVertex]
        let darkness: Float
        let vignetteAlpha: Float
        let accentWash: SIMD4<Float>
        let mesh: VisualizerMesh
        let title: MetalRenderer.TextureLayer?
        let lyrics: MetalRenderer.TextureLayer?
        let backgroundMotion: BackgroundMotionSettings
        let postProcess: PostProcessSettings
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
        let sceneProfile = cachedSceneProfile(identifier: backgroundIdentifier, image: background)
        let effectiveSettings = settings
        let palette = settings.template.palette.adapted(to: sceneProfile, strength: 0.58)

        var layers: [MetalRenderer.TextureLayer] = []
        var placeholder: [GPUVertex] = []
        if let background {
            let state = backgroundTimeline ?? BackgroundTimelineState(currentIndex: 0, nextIndex: nil, currentLocalTime: time, nextLocalTime: 0, segmentDuration: max(time, 300), transitionProgress: 0)
            let progress = CGFloat(min(1, max(0, state.transitionProgress)))
            if let nextBackground, state.nextIndex != nil {
                let transition: BackgroundTransition = state.nextIndex == state.currentIndex ? .crossfade : effectiveSettings.backgroundTransition
                switch transition {
                case .crossfade:
                    appendBackgroundLayer(&layers, image: background, identifier: backgroundIdentifier, mediaDuration: backgroundDuration, localTime: state.currentLocalTime, segmentDuration: state.segmentDuration, alpha: 1, offsetX: 0, extraZoom: 1, size: size, settings: effectiveSettings)
                    appendBackgroundLayer(&layers, image: nextBackground, identifier: nextBackgroundIdentifier, mediaDuration: nextBackgroundDuration, localTime: state.nextLocalTime, segmentDuration: state.segmentDuration, alpha: progress, offsetX: 0, extraZoom: 1, size: size, settings: effectiveSettings)
                case .slide:
                    appendBackgroundLayer(&layers, image: background, identifier: backgroundIdentifier, mediaDuration: backgroundDuration, localTime: state.currentLocalTime, segmentDuration: state.segmentDuration, alpha: 1, offsetX: -progress * size.width, extraZoom: 1, size: size, settings: effectiveSettings)
                    appendBackgroundLayer(&layers, image: nextBackground, identifier: nextBackgroundIdentifier, mediaDuration: nextBackgroundDuration, localTime: state.nextLocalTime, segmentDuration: state.segmentDuration, alpha: 1, offsetX: (1 - progress) * size.width, extraZoom: 1, size: size, settings: effectiveSettings)
                case .zoom:
                    appendBackgroundLayer(&layers, image: background, identifier: backgroundIdentifier, mediaDuration: backgroundDuration, localTime: state.currentLocalTime, segmentDuration: state.segmentDuration, alpha: 1, offsetX: 0, extraZoom: 1 + progress * 0.08, size: size, settings: effectiveSettings)
                    appendBackgroundLayer(&layers, image: nextBackground, identifier: nextBackgroundIdentifier, mediaDuration: nextBackgroundDuration, localTime: state.nextLocalTime, segmentDuration: state.segmentDuration, alpha: progress, offsetX: 0, extraZoom: 1.08 - progress * 0.08, size: size, settings: effectiveSettings)
                case .none:
                    appendBackgroundLayer(&layers, image: nextBackground, identifier: nextBackgroundIdentifier, mediaDuration: nextBackgroundDuration, localTime: state.nextLocalTime, segmentDuration: state.segmentDuration, alpha: 1, offsetX: 0, extraZoom: 1, size: size, settings: effectiveSettings)
                }
            } else {
                appendBackgroundLayer(&layers, image: background, identifier: backgroundIdentifier, mediaDuration: backgroundDuration, localTime: state.currentLocalTime, segmentDuration: state.segmentDuration, alpha: 1, offsetX: 0, extraZoom: 1, size: size, settings: effectiveSettings)
            }
        } else {
            placeholder = visualizerEngine.placeholder(size: size, time: time, palette: palette)
        }

        let features = analysis?.frame(at: time) ?? .silent
        let directedFeatures = features.directed(amount: Float(effectiveSettings.musicAwareness))
        let visualizerMesh = visualizerEngine.mesh(
            kind: effectiveSettings.visualizer,
            size: size,
            features: features,
            settings: effectiveSettings,
            time: time,
            palette: palette,
            staticBackground: background != nil && backgroundDuration <= 0
        )
        let atmosphere = atmosphereEngine.frame(
            size: size,
            features: directedFeatures,
            settings: effectiveSettings,
            time: time,
            palette: palette,
            scene: sceneProfile
        )
        var mesh = atmosphere.mesh
        mesh.soft.append(contentsOf: visualizerMesh.soft)
        mesh.volumes.append(contentsOf: visualizerMesh.volumes)
        mesh.radials.append(contentsOf: visualizerMesh.radials)
        mesh.additive.append(contentsOf: visualizerMesh.additive)
        let overlayAlpha = Float(min(1, max(0, effectiveSettings.backgroundOverlayOpacity)))
        let overlay = SIMD4<Float>(
            Float(min(1, max(0, effectiveSettings.backgroundOverlayRed))) * overlayAlpha,
            Float(min(1, max(0, effectiveSettings.backgroundOverlayGreen))) * overlayAlpha,
            Float(min(1, max(0, effectiveSettings.backgroundOverlayBlue))) * overlayAlpha,
            overlayAlpha
        )
        let lyricsLayer: MetalRenderer.TextureLayer?
        if LRCParser.currentIndex(at: time, in: lyrics) != nil {
            let lyricContrast = makeLyricContrastProfile(
                background: background,
                backgroundIdentifier: backgroundIdentifier,
                nextBackground: nextBackground,
                nextBackgroundIdentifier: nextBackgroundIdentifier,
                transitionProgress: backgroundTimeline?.transitionProgress ?? 0,
                size: size,
                settings: effectiveSettings
            )
            lyricsLayer = makeLyricsLayer(lyrics, size: size, time: time, settings: effectiveSettings, fontName: fontName, features: features, contrast: lyricContrast, palette: palette)
        } else {
            lyricsLayer = nil
        }
        let titleLayer = makeIntroLayer(
            size: size,
            time: time,
            settings: effectiveSettings,
            fontName: fontName,
            features: directedFeatures,
            palette: palette
        )
        let postProcess = PostProcessSettings(
            time: time,
            center: SIMD2(0.5, Float(min(0.92, max(0.08, effectiveSettings.visualizerPositionY)))),
            bass: directedFeatures.bass,
            mid: directedFeatures.mid,
            high: directedFeatures.high,
            beat: directedFeatures.beat,
            integration: Float(effectiveSettings.visualizerIntegration),
            brilliance: Float(effectiveSettings.visualizerBrilliance),
            trail: Float(effectiveSettings.visualizerTrail),
            colorRichness: Float(effectiveSettings.visualizerColorRichness),
            depth: Float(effectiveSettings.visualizerDepth),
            beatImpact: Float(effectiveSettings.visualizerBeatImpact),
            energy: directedFeatures.energy,
            transient: directedFeatures.transient,
            buildup: directedFeatures.buildup,
            climax: directedFeatures.climax,
            quiet: directedFeatures.quiet,
            warmth: directedFeatures.warmth,
            sectionProgress: directedFeatures.sectionProgress,
            musicAwareness: Float(effectiveSettings.musicAwareness),
            atmosphereWaterStrength: atmosphere.waterStrength,
            atmosphereWaterline: Float(min(0.88, max(0.48, effectiveSettings.atmosphereWaterline))),
            atmosphereAirStrength: atmosphere.airStrength,
            atmosphereAirMode: atmosphere.airMode
        )
        let backgroundMotion = BackgroundMotionSettings(
            time: time,
            center: SIMD2(0.5, Float(min(0.92, max(0.08, effectiveSettings.visualizerPositionY)))),
            features: directedFeatures,
            style: effectiveSettings.backgroundMotionStyle,
            life: Float(effectiveSettings.backgroundLife),
            camera: Float(effectiveSettings.backgroundCameraMotion),
            warp: Float(effectiveSettings.backgroundAudioWarp),
            parallax: Float(effectiveSettings.backgroundParallax),
            lightFlow: Float(effectiveSettings.backgroundLightFlow),
            subjectProtection: Float(effectiveSettings.backgroundSubjectProtection),
            awareness: Float(effectiveSettings.musicAwareness),
            smartCompositionEnabled: effectiveSettings.smartCompositionEnabled,
            edgeLight: Float(effectiveSettings.subjectEdgeLight)
        )
        return PreparedFrame(
            backgrounds: layers,
            placeholder: placeholder,
            darkness: 0,
            vignetteAlpha: Float(min(0.85, effectiveSettings.darkness * (effectiveSettings.template == .cinema ? 1.18 : 1.0))),
            accentWash: overlay,
            mesh: mesh,
            title: titleLayer,
            lyrics: lyricsLayer,
            backgroundMotion: backgroundMotion,
            postProcess: postProcess
        )
    }

    private func cachedSceneProfile(identifier: String?, image: CGImage?) -> SceneColorProfile? {
        guard let image else { return nil }
        let key = identifier ?? "image-\(image.width)x\(image.height)-\(ObjectIdentifier(image).hashValue)"
        if let cached = sceneColorCache[key] { return cached }
        guard let profile = SceneColorAnalyzer.analyze(image) else { return nil }
        if sceneColorCache.count > 48 { sceneColorCache.removeAll(keepingCapacity: true) }
        sceneColorCache[key] = profile
        return profile
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
        let motionEnabled = isStatic && settings.backgroundMotionStyle != .off
        let zoomProgress = motionEnabled ? min(1, max(0, localTime / max(0.001, segmentDuration))) : 0
        let breathingZoom = motionEnabled ? 0.004 * (0.5 + 0.5 * sin(localTime * 0.16)) : 0
        let baseZoom = motionEnabled ? 1.014 + 0.026 * zoomProgress + breathingZoom : 1
        let zoom = CGFloat(baseZoom) * extraZoom
        let container = CGRect(x: offsetX, y: 0, width: size.width, height: size.height)
        var imageRect = aspectFillRect(imageSize: CGSize(width: texture.width, height: texture.height), in: container, zoom: zoom)
        if motionEnabled {
            let availableX = max(0, (imageRect.width - container.width) * 0.24)
            let availableY = max(0, (imageRect.height - container.height) * 0.24)
            imageRect.origin.x += sin(localTime * 0.055) * availableX
            imageRect.origin.y += cos(localTime * 0.043) * availableY
        }
        let reactivity: Float = settings.backgroundMotionStyle == .off ? 0 : (isStatic ? 1 : 0.16)
        let subjectMask = isStatic ? subjectMaskTexture(for: image, identifier: identifier) : nil
        layers.append(MetalRenderer.TextureLayer(texture: texture, rect: imageRect, alpha: Float(alpha), backgroundReactivity: reactivity, subjectMask: subjectMask))
    }

    private func subjectMaskTexture(for image: CGImage, identifier: String?) -> MTLTexture? {
        guard let identifier else { return nil }
        if let cached = subjectMaskTextures[identifier] { return cached }
        guard VisionSubjectMaskCache.shared.layoutProfile(for: identifier, image: image)?.supportsSpatialComposition == true,
              let mask = VisionSubjectMaskCache.shared.mask(for: identifier, image: image),
              let texture = metal.makeTexture(width: mask.width, height: mask.height) else { return nil }
        metal.renderCIImage(CIImage(cgImage: mask), to: texture)
        if subjectMaskTextures.count > 32 { subjectMaskTextures.removeAll(keepingCapacity: true) }
        subjectMaskTextures[identifier] = texture
        return texture
    }

    private func filteredBackground(_ image: CGImage, identifier: String?, mediaDuration: Double, targetSize: CGSize, settings: RenderSettings) -> MTLTexture? {
        if mediaDuration <= 0, let identifier {
            let key = BackgroundCacheKey(identifier: identifier, blur: Int(settings.blur * 10), smartBlur: settings.smartBlurEnabled, saturation: Int(settings.saturation * 100), width: Int(targetSize.width), height: Int(targetSize.height))
            if let cached = backgroundCache[key] { return cached }
            guard let texture = makeFilteredTexture(image, identifier: identifier, isStatic: true, targetSize: targetSize, settings: settings) else { return nil }
            if backgroundCache.count > 24 { backgroundCache.removeAll(keepingCapacity: true) }
            backgroundCache[key] = texture
            return texture
        }
        return makeFilteredTexture(image, identifier: identifier, isStatic: false, targetSize: targetSize, settings: settings)
    }

    private func makeFilteredTexture(_ image: CGImage, identifier: String?, isStatic: Bool, targetSize: CGSize, settings: RenderSettings) -> MTLTexture? {
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
            let sharpImage = ciImage
            filter.setValue(sharpImage, forKey: kCIInputImageKey)
            filter.setValue(settings.blur * renderScale * blurWorkingScale, forKey: kCIInputRadiusKey)
            let blurredImage = filter.outputImage?.cropped(to: sharpImage.extent) ?? sharpImage
            if settings.smartBlurEnabled,
               isStatic,
               let mask = VisionSubjectMaskCache.shared.mask(for: identifier, image: image) {
                ciImage = Self.smartBlurComposite(sharp: sharpImage, blurred: blurredImage, mask: mask)
            } else {
                ciImage = blurredImage
            }
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

    static func smartBlurComposite(sharp: CIImage, blurred: CIImage, mask: CGImage) -> CIImage {
        let maskImage = CIImage(cgImage: mask)
        let scaleX = sharp.extent.width / max(1, maskImage.extent.width)
        let scaleY = sharp.extent.height / max(1, maskImage.extent.height)
        let fittedMask = maskImage
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .transformed(by: CGAffineTransform(translationX: sharp.extent.minX, y: sharp.extent.minY))
            .cropped(to: sharp.extent)
        return sharp
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: blurred,
                kCIInputMaskImageKey: fittedMask
            ])
            .cropped(to: sharp.extent)
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

        let effectiveLuminance = sample.average * CGFloat(max(0, 1 - settings.darkness * 0.16))
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

    private func makeIntroLayer(
        size: CGSize,
        time: Double,
        settings: RenderSettings,
        fontName: String,
        features: AudioFrameFeatures,
        palette: VisualPalette
    ) -> MetalRenderer.TextureLayer? {
        let title = settings.songTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.introEnabled, !title.isEmpty, time >= 0, time <= settings.introDuration else { return nil }
        let portraitLayout = settings.aspectRatio != .landscape
        let clip: CGRect
        if portraitLayout {
            clip = CGRect(x: size.width * 0.055, y: size.height * 0.745, width: size.width * 0.89, height: size.height * 0.22)
        } else {
            clip = CGRect(x: size.width * 0.035, y: size.height * 0.69, width: size.width * 0.57, height: size.height * 0.27)
        }
        let width = max(1, Int(clip.width.rounded(.up)))
        let height = max(1, Int(clip.height.rounded(.up)))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.translateBy(x: -clip.minX, y: -clip.minY)
        drawIntro(
            title: title,
            author: settings.authorName.trimmingCharacters(in: .whitespacesAndNewlines),
            date: settings.introShowsDate ? Self.currentDateString() : "",
            in: context,
            size: size,
            time: time,
            settings: settings,
            fontName: fontName,
            features: features,
            palette: palette
        )
        guard let image = context.makeImage() else { return nil }
        if introTexture?.width != width || introTexture?.height != height {
            introTexture = metal.makeTexture(width: width, height: height)
        }
        guard let introTexture else { return nil }
        metal.renderCIImage(CIImage(cgImage: image), to: introTexture)
        return MetalRenderer.TextureLayer(texture: introTexture, rect: clip, alpha: 1)
    }

    private func drawIntro(
        title: String,
        author: String,
        date: String,
        in context: CGContext,
        size: CGSize,
        time: Double,
        settings: RenderSettings,
        fontName: String,
        features: AudioFrameFeatures,
        palette: VisualPalette
    ) {
        let landscape = settings.aspectRatio == .landscape
        let renderScale = size.width / max(1, settings.aspectRatio.size1080.width)
        let titleSize = CGFloat(settings.introTitleSize) * renderScale
        let alignment: LyricAlignment = landscape ? .leading : .center
        let left = landscape ? size.width * 0.055 : size.width * 0.08
        let textWidth = landscape ? size.width * 0.48 : size.width * 0.84
        let titleY = landscape ? size.height * 0.865 : size.height * 0.885
        let authorY = titleY - titleSize * 1.06
        let dateY = authorY - titleSize * 0.62
        let baseGlow = CGFloat(settings.lyricGlow) * renderScale * (18 + CGFloat(features.climax) * 8)

        let backdropCenter = CGPoint(
            x: landscape ? left + textWidth * 0.34 : size.width * 0.5,
            y: titleY - titleSize * 0.55
        )
        let overall = introAnimation(time: time, delay: 0, settings: settings)
        drawLyricScrim(
            center: backdropCenter,
            width: landscape ? textWidth * 1.18 : textWidth * 1.08,
            height: titleSize * 3.6,
            alpha: 0.22 * overall.alpha,
            in: context
        )

        let titleMotion = introAnimation(time: time, delay: 0.08, settings: settings)
        drawIntroText(
            title,
            centerY: titleY + titleMotion.offset,
            left: left,
            width: textWidth,
            fontName: fontName,
            fontSize: titleSize,
            alignment: alignment,
            alpha: titleMotion.alpha,
            scale: titleMotion.scale,
            color: VisualPalette.mix(palette.highlight, CGColor(gray: 1, alpha: 1), 0.55),
            glowColor: palette.accent,
            glow: settings.introAnimationStyle == .minimal ? 0 : baseGlow,
            in: context
        )

        let authorMotion = introAnimation(time: time, delay: 0.26, settings: settings)
        if !author.isEmpty {
            drawIntroText(
                author,
                centerY: authorY + authorMotion.offset,
                left: left,
                width: textWidth,
                fontName: fontName,
                fontSize: titleSize * 0.46,
                alignment: alignment,
                alpha: authorMotion.alpha * 0.88,
                scale: authorMotion.scale,
                color: VisualPalette.mix(palette.accent, CGColor(gray: 1, alpha: 1), 0.45),
                glowColor: palette.secondary,
                glow: baseGlow * 0.45,
                in: context
            )
        }

        let dateMotion = introAnimation(time: time, delay: 0.42, settings: settings)
        if !date.isEmpty {
            drawIntroText(
                date,
                centerY: dateY + dateMotion.offset,
                left: left,
                width: textWidth,
                fontName: "SFMono-Regular",
                fontSize: titleSize * 0.30,
                alignment: alignment,
                alpha: dateMotion.alpha * 0.62,
                scale: 1,
                color: CGColor(gray: 0.92, alpha: 1),
                glowColor: palette.cool,
                glow: baseGlow * 0.22,
                in: context
            )
        }
    }

    private func introAnimation(time: Double, delay: Double, settings: RenderSettings) -> (alpha: CGFloat, offset: CGFloat, scale: CGFloat) {
        let animation = max(0.18, settings.introAnimationDuration)
        let enter = smoothstep(0, 1, CGFloat((time - delay) / animation))
        let exitStart = max(animation + delay + 0.2, settings.introDuration - animation)
        let exit = 1 - smoothstep(0, 1, CGFloat((time - exitStart) / animation))
        let alpha = max(0, min(1, enter * exit))
        switch settings.introAnimationStyle {
        case .luminousRise:
            return (alpha, (1 - enter) * -18, 0.96 + enter * 0.04)
        case .cinematic:
            return (alpha, (1 - enter) * -7, 1.025 - enter * 0.025)
        case .minimal:
            return (alpha, 0, 1)
        }
    }

    private func drawIntroText(
        _ text: String,
        centerY: CGFloat,
        left: CGFloat,
        width: CGFloat,
        fontName: String,
        fontSize: CGFloat,
        alignment: LyricAlignment,
        alpha: CGFloat,
        scale: CGFloat,
        color: CGColor,
        glowColor: CGColor,
        glow: CGFloat,
        in context: CGContext
    ) {
        guard alpha > 0.001, !text.isEmpty else { return }
        var font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        var line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        var bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        if bounds.width > width, bounds.width > 0 {
            font = CTFontCreateCopyWithAttributes(font, fontSize * max(0.62, width / bounds.width), nil, nil)
            line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
            bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        }
        let x: CGFloat
        switch alignment {
        case .leading: x = left
        case .center: x = left + (width - bounds.width) / 2
        case .trailing: x = left + width - bounds.width
        }
        let anchorX = alignment == .center ? x + bounds.width / 2 : x
        let y = centerY - bounds.height / 2
        context.saveGState()
        context.setAlpha(alpha)
        if scale != 1 {
            context.translateBy(x: anchorX, y: centerY)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -anchorX, y: -centerY)
        }
        if glow > 0 {
            context.setShadow(offset: .zero, blur: glow, color: glowColor.copy(alpha: min(0.55, alpha * 0.48)))
        }
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func currentDateString() -> String {
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private func makeLyricsLayer(_ lines: [LRCLine], size: CGSize, time: Double, settings: RenderSettings, fontName: String, features: AudioFrameFeatures, contrast: LyricContrastProfile, palette: VisualPalette) -> MetalRenderer.TextureLayer? {
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
        drawLyrics(lines, in: context, size: size, time: time, settings: settings, fontName: fontName, features: features, contrast: contrast, palette: palette)
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

    private func drawLyrics(_ lines: [LRCLine], in context: CGContext, size: CGSize, time: Double, settings: RenderSettings, fontName: String, features: AudioFrameFeatures, contrast: LyricContrastProfile, palette: VisualPalette) {
        guard let current = LRCParser.currentIndex(at: time, in: lines) else { return }
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
            let inactiveAlpha = min(0.76, CGFloat(settings.lyricInactiveOpacity) + contrast.inactiveOpacityBoost)
            let alpha = Self.lyricTransitionOpacity(
                relation: relation,
                progress: progress,
                inactive: inactiveAlpha,
                animation: settings.lyricAnimation
            )
            let emphasis = Self.lyricTransitionEmphasis(
                relation: relation,
                progress: progress,
                animation: settings.lyricAnimation
            )
            var scale: CGFloat = 1
            var glowBoost: CGFloat = 1
            var karaoke: CGFloat? = nil
            switch settings.lyricAnimation {
            case .scroll:
                y -= (1 - progress) * lineHeight
            case .fade:
                break
            case .scale:
                if relation == 0 {
                    scale = 0.86 + progress * 0.16 + beat * 0.03
                    glowBoost = 0.85 + progress * 0.35
                }
            case .karaoke:
                if relation == 0 {
                    karaoke = karaokeProgress
                    glowBoost = 0.9 + beat * 0.35
                }
            case .bloom:
                if relation == 0 {
                    scale = 0.92 + progress * 0.10 + beat * 0.04
                    y += (1 - progress) * fontSize * 0.18
                    glowBoost = 0.7 + progress * 0.85 + beat * 0.45
                }
            case .none:
                break
            }
            let activeColor = VisualPalette.mix(CGColor(gray: 1, alpha: 1), palette.lyric, 0.42)
            let inactiveColor = VisualPalette.mix(CGColor(gray: 1, alpha: 1), palette.secondary, 0.36)
            let fillColor = VisualPalette.mix(inactiveColor, activeColor, emphasis).copy(alpha: alpha) ?? activeColor
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
                emphasis: emphasis,
                glow: CGFloat(settings.lyricGlow) * 36 * renderScale * glowBoost * contrast.glowFactor * (0.18 + emphasis * 0.82),
                outlineAlpha: contrast.outlineAlpha,
                outlineRadius: contrast.outlineRadius * renderScale,
                karaokeProgress: karaoke,
                beat: beat,
                in: context
            )
        }
    }

    static func lyricTransitionOpacity(
        relation: Int,
        progress: CGFloat,
        inactive: CGFloat,
        animation: LyricAnimation
    ) -> CGFloat {
        let low = min(1, max(0, inactive))
        guard animation != .none else { return relation == 0 ? 1 : low }
        let t = min(1, max(0, progress))
        switch relation {
        case 0:
            return low + (1 - low) * t
        case -1:
            return 1 - (1 - low) * t
        default:
            return low
        }
    }

    static func lyricTransitionEmphasis(
        relation: Int,
        progress: CGFloat,
        animation: LyricAnimation
    ) -> CGFloat {
        guard animation != .none else { return relation == 0 ? 1 : 0 }
        let t = min(1, max(0, progress))
        if relation == 0 { return t }
        if relation == -1 { return 1 - t }
        return 0
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
        emphasis: CGFloat,
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

        if emphasis > 0.001, glow > 0 {
            context.saveGState()
            context.setBlendMode(.plusLighter)
            if let inner = VisualPalette.mix(glowColor, secondaryGlowColor, 0.4).copy(alpha: (0.14 + beat * 0.10) * emphasis),
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
        if emphasis > 0.001, glow > 0 {
            context.saveGState()
            context.setBlendMode(.plusLighter)
            let colorOffset = max(0.6, min(2.4, glow * 0.045))
            let chromatic = NSAttributedString(
                string: content,
                attributes: [
                    .font: activeFont,
                    .foregroundColor: secondaryGlowColor.copy(alpha: 0.15 * emphasis) ?? secondaryGlowColor
                ]
            )
            let chromaticLine = CTLineCreateWithAttributedString(chromatic)
            context.setShadow(
                offset: CGSize(width: -colorOffset, height: colorOffset * 0.45),
                blur: min(30, glow * 0.72),
                color: secondaryGlowColor.copy(alpha: 0.30 * emphasis)
            )
            context.textPosition = CGPoint(x: x + colorOffset, y: textY)
            CTLineDraw(chromaticLine, context)
            context.restoreGState()

            context.textPosition = CGPoint(x: x, y: textY)
            context.setShadow(offset: .zero, blur: min(22, glow * 0.42), color: glowColor.copy(alpha: 0.40 * emphasis))
        }
        CTLineDraw(line, context)
        context.setShadow(offset: .zero, blur: 0, color: nil)

        if emphasis > 0.001, let karaokeProgress {
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

        if emphasis > 0.001 {
            let underlineWidth = max(18, bounds.width * (karaokeProgress ?? (0.42 + beat * 0.2)))
            let underlineX: CGFloat
            switch alignment {
            case .leading: underlineX = x
            case .center: underlineX = anchorX - underlineWidth / 2
            case .trailing: underlineX = x + bounds.width - underlineWidth
            }
            context.setBlendMode(.plusLighter)
            context.setFillColor(glowColor.copy(alpha: (0.20 + beat * 0.16) * emphasis) ?? glowColor)
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
