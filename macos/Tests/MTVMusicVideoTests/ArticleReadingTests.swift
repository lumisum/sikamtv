import CoreGraphics
import XCTest
@testable import MTVMusicVideo

final class ArticleReadingTests: XCTestCase {
    func testArticleDurationUsesLanguageAppropriateReadingUnitsAndEndHold() {
        let chinese = String(repeating: "春", count: 260)
        let english = Array(repeating: "music", count: 180).joined(separator: " ")
        let chineseDuration = ArticleReadingTiming.duration(text: chinese, language: .chinese, rate: 260, endHold: 3)
        let englishDuration = ArticleReadingTiming.duration(text: english, language: .english, rate: 180, endHold: 3)

        XCTAssertEqual(chineseDuration, 63, accuracy: 0.1)
        XCTAssertEqual(englishDuration, 63, accuracy: 0.1)
        XCTAssertEqual(ArticleReadingTiming.defaultRate(for: .chinese), 220)
        XCTAssertEqual(ArticleReadingTiming.defaultRate(for: .english), 150)
    }

    func testArticlePaginatesLongTextWithoutDroppingContent() throws {
        let text = Array(repeating: "音乐让文字慢慢抵达心里。", count: 80).joined(separator: "\n")
        let layout = try XCTUnwrap(ArticlePageLayout(
            text: text,
            fontName: "PingFangSC-Regular",
            fontSize: 26,
            lineSpacing: 1.55,
            pageSize: CGSize(width: 420, height: 260)
        ))
        XCTAssertGreaterThan(layout.pageCount, 1)
    }

    func testArticleModeHasAStableMinimumDuration() {
        XCTAssertEqual(ArticleReadingTiming.duration(text: "短文", language: .chinese, rate: 400, endHold: 1), 12, accuracy: 0.001)
        XCTAssertEqual(ArticleReadingTiming.duration(text: "", language: .chinese, rate: 260, endHold: 3), 0, accuracy: 0.001)
    }

    func testLongerPagesReceiveMoreReadingTimeWhileKeepingAStableDwell() {
        let timings = ArticleReadingTiming.pageTimings(unitCounts: [30, 180, 60], readingDuration: 42)
        XCTAssertEqual(timings.count, 3)
        XCTAssertGreaterThan(timings[1].duration, timings[0].duration)
        XCTAssertGreaterThan(timings[1].duration, timings[2].duration)
        XCTAssertGreaterThanOrEqual(timings[0].duration, 0.55)
        XCTAssertEqual(timings.last?.end ?? 0, 42, accuracy: 0.001)
        XCTAssertLessThanOrEqual(timings[1].transitionDuration, 1.1)
    }
}
