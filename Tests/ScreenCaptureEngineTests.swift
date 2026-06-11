import XCTest
@testable import ZhiKong

final class ScreenCaptureEngineTests: XCTestCase {
    func test_outputSize_nilMax_keepsNative() {
        let (w, h) = ScreenCaptureEngine.outputSize(displayW: 5120, displayH: 2880, maxDimension: nil)
        XCTAssertEqual(w, 5120)
        XCTAssertEqual(h, 2880)
    }

    func test_outputSize_displaySmallerThanMax_keepsNative() {
        let (w, h) = ScreenCaptureEngine.outputSize(displayW: 1440, displayH: 900, maxDimension: 1920)
        XCTAssertEqual(w, 1440)
        XCTAssertEqual(h, 900)
    }

    func test_outputSize_downscalesLongEdgeToMax_preservesAspectEven() {
        // 5120x2880 (16:9) → 长边 1920 → 1920x1080
        let (w, h) = ScreenCaptureEngine.outputSize(displayW: 5120, displayH: 2880, maxDimension: 1920)
        XCTAssertEqual(w, 1920)
        XCTAssertEqual(h, 1080)
    }

    func test_outputSize_alwaysEven() {
        // 3440x1440 超宽 → 长边 1920 → 1920x803.7→802(偶)
        let (w, h) = ScreenCaptureEngine.outputSize(displayW: 3440, displayH: 1440, maxDimension: 1920)
        XCTAssertEqual(w % 2, 0)
        XCTAssertEqual(h % 2, 0)
        XCTAssertEqual(w, 1920)
        XCTAssertTrue(abs(Double(h) - 1440.0 * 1920.0 / 3440.0) <= 2, "高度应约等比缩放,实际 \(h)")
    }

    func test_outputSize_portraitDisplay_usesLongEdge() {
        // 竖屏 1440x2560 → 长边=2560 缩到 1920 → 高 1920, 宽 1080
        let (w, h) = ScreenCaptureEngine.outputSize(displayW: 1440, displayH: 2560, maxDimension: 1920)
        XCTAssertEqual(h, 1920)
        XCTAssertEqual(w, 1080)
    }
}
