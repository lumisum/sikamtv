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
}
