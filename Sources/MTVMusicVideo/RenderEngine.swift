import AppKit
import CoreImage
import CoreText
import Foundation
import Metal

final class RenderEngine {
    private struct BackgroundCacheKey: Hashable {
        let identifier: String
        let blur: Int
        let saturation: Int
        let width: Int
        let height: Int
    }

    private let ciContext: CIContext = {
        let options: [CIContextOption: Any] = [.useSoftwareRenderer: false, .cacheIntermediates: true]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }()
    private let visualizerEngine = VisualizerEngine()
    private var backgroundCache: [BackgroundCacheKey: CGImage] = [:]

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
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        render(
            into: context,
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
        return context.makeImage()
    }

    /// Draws directly into a caller-owned bitmap context. Export uses this path
    /// to avoid creating and copying an intermediate full-resolution CGImage.
    func render(
        into context: CGContext,
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
    ) {
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: size))

        if let background {
            drawBackgroundSequence(
                background,
                identifier: backgroundIdentifier,
                mediaDuration: backgroundDuration,
                next: nextBackground,
                nextIdentifier: nextBackgroundIdentifier,
                nextMediaDuration: nextBackgroundDuration,
                timeline: backgroundTimeline,
                in: context,
                size: size,
                time: time,
                settings: settings
            )
        } else {
            drawPlaceholderBackground(in: context, size: size, time: time, settings: settings)
        }
        drawVignette(in: context, size: size, template: settings.template)

        let features = analysis?.frame(at: time) ?? .silent
        visualizerEngine.draw(
            kind: settings.visualizer,
            in: context,
            size: size,
            features: features,
            settings: settings,
            color: settings.template.accent,
            time: time,
            template: settings.template
        )
        drawLyrics(lyrics, in: context, size: size, time: time, settings: settings, fontName: fontName)
    }

    private func drawBackgroundSequence(_ image: CGImage, identifier: String?, mediaDuration: Double, next: CGImage?, nextIdentifier: String?, nextMediaDuration: Double, timeline: BackgroundTimelineState?, in context: CGContext, size: CGSize, time: Double, settings: RenderSettings) {
        let state = timeline ?? BackgroundTimelineState(currentIndex: 0, nextIndex: nil, currentLocalTime: time, nextLocalTime: 0, segmentDuration: max(time, 300), transitionProgress: 0)
        let progress = CGFloat(min(1, max(0, state.transitionProgress)))
        context.saveGState()
        context.clip(to: CGRect(origin: .zero, size: size))
        if let next, state.nextIndex != nil {
            let transition: BackgroundTransition = state.nextIndex == state.currentIndex ? .crossfade : settings.backgroundTransition
            switch transition {
            case .crossfade:
                drawBackgroundLayer(image, identifier: identifier, mediaDuration: mediaDuration, localTime: state.currentLocalTime, segmentDuration: state.segmentDuration, alpha: 1, offsetX: 0, extraZoom: 1, in: context, size: size, settings: settings)
                drawBackgroundLayer(next, identifier: nextIdentifier, mediaDuration: nextMediaDuration, localTime: state.nextLocalTime, segmentDuration: state.segmentDuration, alpha: progress, offsetX: 0, extraZoom: 1, in: context, size: size, settings: settings)
            case .slide:
                drawBackgroundLayer(image, identifier: identifier, mediaDuration: mediaDuration, localTime: state.currentLocalTime, segmentDuration: state.segmentDuration, alpha: 1, offsetX: -progress * size.width, extraZoom: 1, in: context, size: size, settings: settings)
                drawBackgroundLayer(next, identifier: nextIdentifier, mediaDuration: nextMediaDuration, localTime: state.nextLocalTime, segmentDuration: state.segmentDuration, alpha: 1, offsetX: (1 - progress) * size.width, extraZoom: 1, in: context, size: size, settings: settings)
            case .zoom:
                drawBackgroundLayer(image, identifier: identifier, mediaDuration: mediaDuration, localTime: state.currentLocalTime, segmentDuration: state.segmentDuration, alpha: 1, offsetX: 0, extraZoom: 1 + progress * 0.08, in: context, size: size, settings: settings)
                drawBackgroundLayer(next, identifier: nextIdentifier, mediaDuration: nextMediaDuration, localTime: state.nextLocalTime, segmentDuration: state.segmentDuration, alpha: progress, offsetX: 0, extraZoom: 1.08 - progress * 0.08, in: context, size: size, settings: settings)
            case .none:
                drawBackgroundLayer(next, identifier: nextIdentifier, mediaDuration: nextMediaDuration, localTime: state.nextLocalTime, segmentDuration: state.segmentDuration, alpha: 1, offsetX: 0, extraZoom: 1, in: context, size: size, settings: settings)
            }
        } else {
            drawBackgroundLayer(image, identifier: identifier, mediaDuration: mediaDuration, localTime: state.currentLocalTime, segmentDuration: state.segmentDuration, alpha: 1, offsetX: 0, extraZoom: 1, in: context, size: size, settings: settings)
        }
        context.restoreGState()
        context.setFillColor(NSColor.black.withAlphaComponent(settings.darkness).cgColor)
        context.fill(CGRect(origin: .zero, size: size))
    }

    private func drawBackgroundLayer(_ image: CGImage, identifier: String?, mediaDuration: Double, localTime: Double, segmentDuration: Double, alpha: CGFloat, offsetX: CGFloat, extraZoom: CGFloat, in context: CGContext, size: CGSize, settings: RenderSettings) {
        let filtered: CGImage
        if mediaDuration <= 0, let identifier {
            let key = BackgroundCacheKey(identifier: identifier, blur: Int(settings.blur * 10), saturation: Int(settings.saturation * 100), width: Int(size.width), height: Int(size.height))
            if let cached = backgroundCache[key] { filtered = cached }
            else {
                guard let result = filteredBackground(image, targetSize: size, settings: settings) else { return }
                if backgroundCache.count > 24 { backgroundCache.removeAll(keepingCapacity: true) }
                backgroundCache[key] = result
                filtered = result
            }
        } else {
            guard let result = filteredBackground(image, targetSize: size, settings: settings) else { return }
            filtered = result
        }

        let zoomProgress = mediaDuration > 0 ? 0 : min(1, max(0, localTime / max(0.001, segmentDuration)))
        let zoom = CGFloat(1 + 0.06 * zoomProgress) * extraZoom
        let container = CGRect(x: offsetX, y: 0, width: size.width, height: size.height)
        let imageRect = aspectFillRect(imageSize: CGSize(width: filtered.width, height: filtered.height), in: container, zoom: zoom)
        context.saveGState()
        context.setAlpha(alpha)
        context.draw(filtered, in: imageRect)
        context.restoreGState()
    }

    private func filteredBackground(_ image: CGImage, targetSize: CGSize, settings: RenderSettings) -> CGImage? {
        var ciImage = CIImage(cgImage: image)
        let sourceSize = CGSize(width: image.width, height: image.height)
        let downsampleScale = min(1, max(targetSize.width / max(1, sourceSize.width), targetSize.height / max(1, sourceSize.height)) * 1.06)
        if downsampleScale < 0.999 {
            ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: downsampleScale, y: downsampleScale))
        }
        if settings.blur > 0 {
            let renderScale = targetSize.width / max(1, settings.aspectRatio.size1080.width)
            let filter = CIFilter(name: "CIGaussianBlur")!
            filter.setValue(ciImage, forKey: kCIInputImageKey)
            filter.setValue(settings.blur * renderScale, forKey: kCIInputRadiusKey)
            ciImage = filter.outputImage?.cropped(to: ciImage.extent) ?? ciImage
        }
        let color = CIFilter(name: "CIColorControls")!
        color.setValue(ciImage, forKey: kCIInputImageKey)
        color.setValue(settings.saturation, forKey: kCIInputSaturationKey)
        ciImage = color.outputImage?.cropped(to: ciImage.extent) ?? ciImage
        return ciContext.createCGImage(ciImage, from: ciImage.extent)
    }

    private func drawPlaceholderBackground(in context: CGContext, size: CGSize, time: Double, settings: RenderSettings) {
        let accent = settings.template.accent
        let darkAccent = accent.copy(alpha: 0.26) ?? accent
        let colors = [CGColor(red: 0.025, green: 0.032, blue: 0.065, alpha: 1), darkAccent] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
        context.setAlpha(0.16)
        context.setFillColor(CGColor.white)
        for index in 0..<24 {
            let phase = CGFloat(time * (0.06 + Double(index % 3) * 0.025))
            let x = CGFloat((index * 97) % max(Int(size.width), 1))
            let y = CGFloat((index * 151) % max(Int(size.height), 1)) + sin(phase) * 20
            context.fillEllipse(in: CGRect(x: x, y: y, width: 1.5, height: 1.5))
        }
        context.setAlpha(1)
    }

    private func drawVignette(in context: CGContext, size: CGSize, template: VisualTemplate) {
        let alpha: CGFloat = template == .cinema ? 0.70 : 0.50
        guard let edge = CGColor.black.copy(alpha: alpha),
              let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [CGColor.clear, edge] as CFArray, locations: [0.38, 1]) else { return }
        context.drawRadialGradient(
            gradient,
            startCenter: CGPoint(x: size.width / 2, y: size.height * 0.50),
            startRadius: min(size.width, size.height) * 0.06,
            endCenter: CGPoint(x: size.width / 2, y: size.height * 0.50),
            endRadius: max(size.width, size.height) * 0.76,
            options: []
        )
    }

    private func aspectFillRect(imageSize: CGSize, in container: CGRect, zoom: CGFloat) -> CGRect {
        let scale = max(container.width / imageSize.width, container.height / imageSize.height) * zoom
        let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: container.midX - fitted.width / 2, y: container.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }

    private func drawLyrics(_ lines: [LRCLine], in context: CGContext, size: CGSize, time: Double, settings: RenderSettings, fontName: String) {
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

        context.saveGState()
        context.addRect(CGRect(x: left - fontSize, y: centerY - lineHeight * 2.1, width: availableWidth + fontSize * 2, height: lineHeight * 4.2))
        context.clip()
        for index in max(0, current - 1)...min(lines.count - 1, current + 1) {
            let relation = index - current
            var y = centerY - CGFloat(relation) * lineHeight
            var alpha = relation == 0 ? CGFloat(1) : CGFloat(settings.lyricInactiveOpacity)
            var scale: CGFloat = 1
            switch settings.lyricAnimation {
            case .scroll:
                y -= (1 - progress) * lineHeight
                if relation == 0 { alpha = 0.35 + progress * 0.65 }
            case .fade:
                if relation == 0 { alpha = 0.2 + progress * 0.8 }
            case .scale:
                if relation == 0 { alpha = 0.25 + progress * 0.75; scale = 0.90 + progress * 0.10 }
            case .none:
                break
            }
            drawText(
                lines[index].text,
                centerY: y,
                left: left,
                width: availableWidth,
                font: font,
                color: NSColor.white.withAlphaComponent(alpha).cgColor,
                alignment: settings.lyricAlignment,
                scale: scale,
                highlight: relation == 0,
                glow: CGFloat(settings.lyricGlow) * 18 * renderScale,
                in: context
            )
        }
        context.restoreGState()
    }

    private func drawText(_ text: String, centerY: CGFloat, left: CGFloat, width: CGFloat, font: CTFont, color: CGColor, alignment: LyricAlignment, scale: CGFloat, highlight: Bool, glow: CGFloat, in context: CGContext) {
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
        context.saveGState()
        if scale != 1 {
            context.translateBy(x: anchorX, y: centerY)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -anchorX, y: -centerY)
        }
        context.textPosition = CGPoint(x: x, y: centerY - bounds.height / 2)
        if highlight, glow > 0 { context.setShadow(offset: .zero, blur: glow, color: NSColor.white.withAlphaComponent(0.38).cgColor) }
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func easeOutCubic(_ value: CGFloat) -> CGFloat {
        1 - pow(1 - value, 3)
    }
}
