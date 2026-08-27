import XCTest
@testable import MTVMusicVideo

final class LRCParserTests: XCTestCase {
    func testParsesMillisecondsAndSortsLines() {
        let input = """
        [00:17.30]一念照见 万境初开
        [00:12.50]观自在 行深般若
        [01:02.005]最后一句
        """

        let result = LRCParser.parse(input)

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].text, "观自在 行深般若")
        XCTAssertEqual(result[0].time, 12.5, accuracy: 0.0001)
        XCTAssertEqual(result[1].time, 17.3, accuracy: 0.0001)
        XCTAssertEqual(result[2].time, 62.005, accuracy: 0.0001)
    }

    func testFindsCurrentLine() {
        let lines = [LRCLine(time: 2, text: "A"), LRCLine(time: 8, text: "B")]
        XCTAssertNil(LRCParser.currentIndex(at: 1.9, in: lines))
        XCTAssertEqual(LRCParser.currentIndex(at: 8, in: lines), 1)
        XCTAssertEqual(LRCParser.currentIndex(at: 30, in: lines), 1)
    }

    func testParsesSRTCuesAndMultilineText() {
        let input = """
        1
        00:00:12,500 --> 00:00:15,000
        观自在
        行深般若

        2
        00:00:17.300 --> 00:00:20.000
        一念照见 <i>万境初开</i>
        """

        let result = LRCParser.parseSRT(input)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].time, 12.5, accuracy: 0.0001)
        XCTAssertEqual(result[0].text, "观自在 行深般若")
        XCTAssertEqual(result[1].time, 17.3, accuracy: 0.0001)
        XCTAssertEqual(result[1].text, "一念照见 万境初开")
    }
}
