import XCTest
@testable import ZhiKong

final class FrameRateCalculatorTests: XCTestCase {
    func test_fps_overOneSecondWindow() {
        var calc = FrameRateCalculator(window: 1.0)
        calc.recordFrame(at: 0.0)
        calc.recordFrame(at: 0.5)
        calc.recordFrame(at: 1.0)
        XCTAssertEqual(calc.fps, 2.0, accuracy: 0.001)
    }
    func test_evictsFramesOutsideWindow() {
        var calc = FrameRateCalculator(window: 1.0)
        calc.recordFrame(at: 0.0)
        calc.recordFrame(at: 0.5)
        calc.recordFrame(at: 1.0)
        calc.recordFrame(at: 1.6)
        XCTAssertEqual(calc.sampleCount, 2)
    }
}
