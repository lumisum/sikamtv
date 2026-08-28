import AppKit
import XCTest
@testable import MTVMusicVideo

final class VisionSubjectMaskTests: XCTestCase {
    func testFaceRegionBecomesASoftProtectionMask() throws {
        let face = CGRect(x: 0.40, y: 0.38, width: 0.20, height: 0.24)
        let mask = try XCTUnwrap(VisionSubjectMaskCache.shared.composeMask(saliencyImage: nil, faceBoxes: [face]))
        XCTAssertEqual(mask.width, 256)
        XCTAssertEqual(mask.height, 256)

        let bitmap = NSBitmapImageRep(cgImage: mask)
        let center = bitmap.colorAt(x: 128, y: 128)?.usingColorSpace(.deviceRGB)?.redComponent ?? 0
        let corner = bitmap.colorAt(x: 8, y: 8)?.usingColorSpace(.deviceRGB)?.redComponent ?? 0
        XCTAssertGreaterThan(center, 0.70, "Detected faces should receive strong protection")
        XCTAssertLessThan(corner, 0.12, "Background areas should remain available for motion")
    }

    func testProtectionMaskProducesReusableCompositionProfile() throws {
        let face = CGRect(x: 0.38, y: 0.46, width: 0.24, height: 0.30)
        let mask = try XCTUnwrap(VisionSubjectMaskCache.shared.composeMask(saliencyImage: nil, faceBoxes: [face]))
        let profile = try XCTUnwrap(VisionSubjectMaskCache.layoutProfile(from: mask))
        XCTAssertTrue(profile.subjectBounds.contains(CGPoint(x: 0.5, y: 0.60)))
        XCTAssertEqual(profile.subjectCenter.x, 0.5, accuracy: 0.08)
        XCTAssertEqual(profile.subjectCenter.y, 0.61, accuracy: 0.12)
        XCTAssertGreaterThan(profile.coverage, 0.03)
    }
}
