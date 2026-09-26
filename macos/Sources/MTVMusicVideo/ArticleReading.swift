import AppKit
import CoreText
import Foundation

enum ArticleReadingTiming {
    static func duration(text: String, language: LyricLanguage, rate: Double, endHold: Double) -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let unitCount: Int
        switch language {
        case .chinese:
            let excluded = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
            unitCount = trimmed.unicodeScalars.filter { !excluded.contains($0) }.count
        case .english:
            unitCount = trimmed.split { $0.isWhitespace || $0.isPunctuation }.count
        }
        let safeRate = max(60, rate)
        let readingSeconds = Double(max(1, unitCount)) / safeRate * 60
        return max(12, readingSeconds + max(1, endHold))
    }

    static func defaultRate(for language: LyricLanguage) -> Double {
        switch language {
        case .chinese: return 220
        case .english: return 150
        }
    }

    static func recommendedRateRange(for language: LyricLanguage) -> ClosedRange<Double> {
        switch language {
        case .chinese: return 120...320
        case .english: return 90...260
        }
    }

    static func unitLabel(for language: LyricLanguage) -> String {
        language == .chinese ? "字 / 分钟" : "词 / 分钟"
    }
}

struct ArticlePageTiming: Equatable {
    let start: Double
    let duration: Double

    var end: Double { start + duration }
    var transitionDuration: Double { min(1.1, max(0.35, duration * 0.14)) }
    var transitionStart: Double { max(start, end - transitionDuration) }
}

extension ArticleReadingTiming {
    /// Allocates the reader's time by the actual amount of text visible on each page.
    /// Every page also receives a stable dwell period before it starts moving.
    static func pageTimings(unitCounts: [Int], readingDuration: Double) -> [ArticlePageTiming] {
        guard !unitCounts.isEmpty, readingDuration > 0 else { return [] }
        let count = Double(unitCounts.count)
        let stableDwell = min(4.5, max(0.55, readingDuration / count * 0.62))
        let reserved = stableDwell * count
        let distributable = max(0, readingDuration - reserved)
        let totalWeight = Double(unitCounts.map { max(1, $0) }.reduce(0, +))
        var start = 0.0
        return unitCounts.map { units in
            let weighted = distributable * Double(max(1, units)) / max(1, totalWeight)
            let timing = ArticlePageTiming(start: start, duration: stableDwell + weighted)
            start = timing.end
            return timing
        }
    }
}

struct ArticlePageLayoutKey: Hashable {
    let text: String
    let fontName: String
    let fontSize: Int
    let lineSpacing: Int
    let width: Int
    let height: Int
}

final class ArticlePageLayout {
    private let framesetter: CTFramesetter
    private let pageRanges: [CFRange]
    private let text: String
    let pageSize: CGSize

    init?(text: String, fontName: String, fontSize: CGFloat, lineSpacing: CGFloat, pageSize: CGSize) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, pageSize.width > 1, pageSize.height > 1 else { return nil }
        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = fontSize * max(0, lineSpacing - 1)
        paragraph.alignment = .left
        let attributed = NSAttributedString(
            string: trimmed,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph
            ]
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(origin: .zero, size: pageSize), transform: nil)
        var ranges: [CFRange] = []
        var location = 0
        let fullLength = (trimmed as NSString).length
        while location < fullLength {
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { break }
            ranges.append(visible)
            location += visible.length
        }
        guard !ranges.isEmpty else { return nil }
        self.framesetter = framesetter
        self.pageRanges = ranges
        self.text = trimmed
        self.pageSize = pageSize
    }

    var pageCount: Int { pageRanges.count }

    func readingUnitCounts(language: LyricLanguage) -> [Int] {
        let string = text as NSString
        return pageRanges.map { range in
            ArticleReadingTiming.readingUnitCount(
                in: string.substring(with: NSRange(location: range.location, length: range.length)),
                language: language
            )
        }
    }

    func draw(page index: Int, in context: CGContext, origin: CGPoint, alpha: CGFloat) {
        guard pageRanges.indices.contains(index), alpha > 0.001 else { return }
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        context.setAlpha(min(1, max(0, alpha)))
        let path = CGPath(rect: CGRect(origin: .zero, size: pageSize), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, pageRanges[index], path, nil)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }
}

private extension ArticleReadingTiming {
    static func readingUnitCount(in text: String, language: LyricLanguage) -> Int {
        switch language {
        case .chinese:
            let excluded = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
            return text.unicodeScalars.filter { !excluded.contains($0) }.count
        case .english:
            return text.split { $0.isWhitespace || $0.isPunctuation }.count
        }
    }
}
