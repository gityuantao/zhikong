import XCTest
import CoreMedia
import CoreVideo
@testable import ZhiKong

final class CaptureSettingsTests: XCTestCase {
    func test_buildsConfigurationWithGivenSizeAndFps() {
        let settings = CaptureSettings(width: 3440, height: 1440, fps: 60, showsCursor: true)
        let config = settings.makeStreamConfiguration()
        XCTAssertEqual(config.width, 3440)
        XCTAssertEqual(config.height, 1440)
        XCTAssertEqual(config.minimumFrameInterval, CMTime(value: 1, timescale: 60))
        XCTAssertEqual(config.pixelFormat, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        XCTAssertTrue(config.showsCursor)
    }
}
