import XCTest
@testable import MTVMusicVideo

final class BackgroundTimelineTests: XCTestCase {
    func testAudioDurationIsEvenlyDividedAcrossBackgrounds() {
        let first = BackgroundTimeline.state(at: 24.9, duration: 100, itemCount: 4, transition: .none, transitionDuration: 1)
        let second = BackgroundTimeline.state(at: 25.1, duration: 100, itemCount: 4, transition: .none, transitionDuration: 1)
        XCTAssertEqual(first?.currentIndex, 0)
        XCTAssertEqual(second?.currentIndex, 1)
        XCTAssertEqual(second?.segmentDuration ?? 0, 25, accuracy: 0.001)
    }

    func testCrossfadeBeginsAtTheScheduledBoundary() {
        let start = BackgroundTimeline.state(at: 25, duration: 100, itemCount: 4, transition: .crossfade, transitionDuration: 0.8)
        let middle = BackgroundTimeline.state(at: 25.4, duration: 100, itemCount: 4, transition: .crossfade, transitionDuration: 0.8)
        let finished = BackgroundTimeline.state(at: 25.9, duration: 100, itemCount: 4, transition: .crossfade, transitionDuration: 0.8)
        XCTAssertEqual(start?.currentIndex, 0)
        XCTAssertEqual(start?.nextIndex, 1)
        XCTAssertEqual(middle?.transitionProgress ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(finished?.currentIndex, 1)
        XCTAssertNil(finished?.nextIndex)
    }

    func testSingleVideoUsesWholeProjectAsOneSegment() {
        let state = BackgroundTimeline.state(at: 42, duration: 180, itemCount: 1, transition: .slide, transitionDuration: 1)
        XCTAssertEqual(state?.currentIndex, 0)
        XCTAssertNil(state?.nextIndex)
        XCTAssertEqual(state?.currentLocalTime, 42)
    }

    func testSingleVideoLoopsUntilTheSongEnds() {
        let video = BackgroundMedia(
            url: URL(fileURLWithPath: "/tmp/background.mov"),
            kind: .video,
            duration: 12
        )
        let timeline = BackgroundTimeline.state(at: 42.5, duration: 180, itemCount: 1, transition: .none, transitionDuration: 0.8)

        XCTAssertEqual(video.playbackTime(for: timeline?.currentLocalTime ?? 0), 6.5, accuracy: 0.001)
    }
}
