import CoreGraphics
import Foundation

struct SceneColorProfile: Sendable, Equatable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let primaryRed: CGFloat
    let primaryGreen: CGFloat
    let primaryBlue: CGFloat
    let secondaryRed: CGFloat
    let secondaryGreen: CGFloat
    let secondaryBlue: CGFloat
    let hueDistance: CGFloat
    let luminance: CGFloat
    let saturation: CGFloat
    let warmth: CGFloat
    let complexity: CGFloat

    init(
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat,
        luminance: CGFloat,
        saturation: CGFloat,
        warmth: CGFloat,
        complexity: CGFloat,
        primaryRed: CGFloat? = nil,
        primaryGreen: CGFloat? = nil,
        primaryBlue: CGFloat? = nil,
        secondaryRed: CGFloat? = nil,
        secondaryGreen: CGFloat? = nil,
        secondaryBlue: CGFloat? = nil,
        hueDistance: CGFloat = 0
    ) {
        self.red = red
        self.green = green
        self.blue = blue
        self.primaryRed = primaryRed ?? red
        self.primaryGreen = primaryGreen ?? green
        self.primaryBlue = primaryBlue ?? blue
        self.secondaryRed = secondaryRed ?? red
        self.secondaryGreen = secondaryGreen ?? green
        self.secondaryBlue = secondaryBlue ?? blue
        self.hueDistance = hueDistance
        self.luminance = luminance
        self.saturation = saturation
        self.warmth = warmth
        self.complexity = complexity
    }
}

enum SceneColorAnalyzer {
    static func analyze(_ image: CGImage?) -> SceneColorProfile? {
        guard let image else { return nil }
        let width = 48
        let height = 48
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var saturation: CGFloat = 0
        var complexity: CGFloat = 0
        let bucketCount = 12
        var bucketWeights = [CGFloat](repeating: 0, count: bucketCount)
        var bucketRed = [CGFloat](repeating: 0, count: bucketCount)
        var bucketGreen = [CGFloat](repeating: 0, count: bucketCount)
        var bucketBlue = [CGFloat](repeating: 0, count: bucketCount)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let r = CGFloat(pixels[offset]) / 255
                let g = CGFloat(pixels[offset + 1]) / 255
                let b = CGFloat(pixels[offset + 2]) / 255
                red += r
                green += g
                blue += b
                let maximum = max(r, g, b)
                let minimum = min(r, g, b)
                let chroma = maximum - minimum
                saturation += chroma
                if chroma > 0.055, maximum > 0.10 {
                    let hue = rgbHue(red: r, green: g, blue: b, maximum: maximum, chroma: chroma)
                    let bucket = min(bucketCount - 1, Int(hue * CGFloat(bucketCount)))
                    let luminance = r * 0.2126 + g * 0.7152 + b * 0.0722
                    let weight = (0.18 + chroma * 1.4) * (0.45 + min(0.8, luminance))
                    bucketWeights[bucket] += weight
                    bucketRed[bucket] += r * weight
                    bucketGreen[bucket] += g * weight
                    bucketBlue[bucket] += b * weight
                }
                if x > 0 {
                    let previous = offset - 4
                    complexity += abs(r - CGFloat(pixels[previous]) / 255)
                        + abs(g - CGFloat(pixels[previous + 1]) / 255)
                        + abs(b - CGFloat(pixels[previous + 2]) / 255)
                }
                if y > 0 {
                    let previous = offset - width * 4
                    complexity += abs(r - CGFloat(pixels[previous]) / 255)
                        + abs(g - CGFloat(pixels[previous + 1]) / 255)
                        + abs(b - CGFloat(pixels[previous + 2]) / 255)
                }
            }
        }
        let count = CGFloat(width * height)
        red /= count
        green /= count
        blue /= count
        saturation /= count
        complexity = min(1, complexity / (count * 1.8))
        let ranked = bucketWeights.indices.sorted { bucketWeights[$0] > bucketWeights[$1] }
        let primaryIndex = ranked.first ?? 0
        let secondaryIndex = ranked.dropFirst().first(where: { index in
            let distance = abs(index - primaryIndex)
            return min(distance, bucketCount - distance) >= 2 && bucketWeights[index] > bucketWeights[primaryIndex] * 0.08
        }) ?? ranked.dropFirst().first ?? primaryIndex

        func bucketColor(_ index: Int, fallback: (CGFloat, CGFloat, CGFloat)) -> (CGFloat, CGFloat, CGFloat) {
            let weight = bucketWeights[index]
            guard weight > 0.001 else { return fallback }
            return (bucketRed[index] / weight, bucketGreen[index] / weight, bucketBlue[index] / weight)
        }
        let primary = bucketColor(primaryIndex, fallback: (red, green, blue))
        let secondary = bucketColor(secondaryIndex, fallback: (red, green, blue))
        let rawDistance = abs(primaryIndex - secondaryIndex)
        let hueDistance = CGFloat(min(rawDistance, bucketCount - rawDistance)) / CGFloat(bucketCount / 2)
        return SceneColorProfile(
            red: red,
            green: green,
            blue: blue,
            luminance: red * 0.2126 + green * 0.7152 + blue * 0.0722,
            saturation: saturation,
            warmth: min(1, max(0, 0.5 + (red - blue) * 0.75)),
            complexity: complexity,
            primaryRed: primary.0,
            primaryGreen: primary.1,
            primaryBlue: primary.2,
            secondaryRed: secondary.0,
            secondaryGreen: secondary.1,
            secondaryBlue: secondary.2,
            hueDistance: hueDistance
        )
    }

    private static func rgbHue(red: CGFloat, green: CGFloat, blue: CGFloat, maximum: CGFloat, chroma: CGFloat) -> CGFloat {
        guard chroma > 0 else { return 0 }
        let sector: CGFloat
        if maximum == red {
            sector = ((green - blue) / chroma).truncatingRemainder(dividingBy: 6)
        } else if maximum == green {
            sector = (blue - red) / chroma + 2
        } else {
            sector = (red - green) / chroma + 4
        }
        let hue = sector / 6
        return hue < 0 ? hue + 1 : hue
    }

}

extension VisualPalette {
    func adapted(to scene: SceneColorProfile?, strength: CGFloat) -> VisualPalette {
        guard let scene else { return self }
        let amount = min(0.78, max(0, strength)) * min(1, 0.30 + scene.saturation * 1.7)
        let primary = CGColor(red: scene.primaryRed, green: scene.primaryGreen, blue: scene.primaryBlue, alpha: 1)
        let secondaryScene = CGColor(red: scene.secondaryRed, green: scene.secondaryGreen, blue: scene.secondaryBlue, alpha: 1)
        let primaryLuminance = scene.primaryRed * 0.2126 + scene.primaryGreen * 0.7152 + scene.primaryBlue * 0.0722
        let secondaryLuminance = scene.secondaryRed * 0.2126 + scene.secondaryGreen * 0.7152 + scene.secondaryBlue * 0.0722
        let luminousPrimary = VisualPalette.mix(primary, CGColor(gray: 1, alpha: 1), primaryLuminance < 0.42 ? 0.48 : 0.30)
        let luminousSecondary = VisualPalette.mix(secondaryScene, CGColor(gray: 1, alpha: 1), secondaryLuminance < 0.42 ? 0.46 : 0.28)
        let relationship = min(1, max(0, scene.hueDistance))
        return VisualPalette(
            accent: Self.mix(accent, luminousPrimary, amount),
            secondary: Self.mix(secondary, luminousSecondary, amount * (0.72 + relationship * 0.18)),
            highlight: Self.mix(highlight, Self.mix(luminousPrimary, luminousSecondary, 0.38), amount * 0.48),
            lyric: Self.mix(lyric, CGColor(gray: 1, alpha: 1), amount * 0.34),
            warm: Self.mix(warm, scene.warmth >= 0.5 ? luminousPrimary : luminousSecondary, amount * 0.82),
            cool: Self.mix(cool, scene.warmth >= 0.5 ? luminousSecondary : luminousPrimary, amount * 0.74)
        )
    }
}
