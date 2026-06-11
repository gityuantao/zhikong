import XCTest
import CoreGraphics
@testable import ZhiKong

final class ContentLayoutTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 500)

    // MARK: - letterbox(fillHeight=false)

    func test_letterbox_widerThanWindow_fitsWidthBlackTopBottom() {
        // 21:9(2.333,比 2:1 窗口更宽)→ 宽受限,上下黑边。
        let r = ContentLayout.rect(videoSize: CGSize(width: 2100, height: 900), bounds: bounds, fillHeight: false, panX: 0)
        XCTAssertEqual(r.width, 1000, accuracy: 0.01)
        XCTAssertEqual(r.height, 1000.0 * 900 / 2100, accuracy: 0.01)  // ≈428.6
        XCTAssertEqual(r.minX, 0, accuracy: 0.01)
        XCTAssertEqual(r.midY, bounds.midY, accuracy: 0.01)  // 垂直居中
    }

    func test_letterbox_narrowerThanWindow_fitsHeightBlackLeftRight() {
        // 16:9(1.778,比 2:1 窗口更窄)→ 高受限,左右黑边。
        let r = ContentLayout.rect(videoSize: CGSize(width: 1920, height: 1080), bounds: bounds, fillHeight: false, panX: 0)
        XCTAssertEqual(r.height, 500, accuracy: 0.01)
        XCTAssertEqual(r.width, 500.0 * 1920 / 1080, accuracy: 0.01)  // ≈888.9
        XCTAssertEqual(r.midX, bounds.midX, accuracy: 0.01)  // 水平居中
    }

    func test_letterbox_tallerThanWindow_fitsHeightBlackLeftRight() {
        // 1:1 视频放进 2:1 窗口 → 高受限,左右黑边。
        let r = ContentLayout.rect(videoSize: CGSize(width: 1000, height: 1000), bounds: bounds, fillHeight: false, panX: 0)
        XCTAssertEqual(r.height, 500, accuracy: 0.01)
        XCTAssertEqual(r.width, 500, accuracy: 0.01)
        XCTAssertEqual(r.midX, bounds.midX, accuracy: 0.01)  // 水平居中
    }

    func test_letterbox_matchesAVMakeRectSemantics_centered() {
        let r = ContentLayout.rect(videoSize: CGSize(width: 800, height: 600), bounds: bounds, fillHeight: false, panX: 0)
        // 4:3 进 2:1 → 高受限:h=500,w=666.67,居中。
        XCTAssertEqual(r.height, 500, accuracy: 0.01)
        XCTAssertEqual(r.width, 500.0 * 800 / 600, accuracy: 0.01)
        XCTAssertEqual(r.midX, bounds.midX, accuracy: 0.01)
        XCTAssertEqual(r.midY, bounds.midY, accuracy: 0.01)
    }

    // MARK: - 填高(fillHeight=true)

    func test_fillHeight_wideContent_overflowsWidth_fullHeight() {
        // 21:9 超宽进 2:1 窗口 → 高填满(500),宽 = 500*21/9 ≈ 1166.7 > 1000 → 溢出。
        let v = CGSize(width: 2100, height: 900)
        let r = ContentLayout.rect(videoSize: v, bounds: bounds, fillHeight: true, panX: 0)
        XCTAssertEqual(r.height, 500, accuracy: 0.01)
        XCTAssertEqual(r.width, 500.0 * 2100 / 900, accuracy: 0.01)
        XCTAssertEqual(r.minX, 0, accuracy: 0.01)  // panX=0 → 左对齐
    }

    func test_fillHeight_panClampedToMax() {
        let v = CGSize(width: 2100, height: 900)
        let maxPan = ContentLayout.maxPanX(videoSize: v, bounds: bounds, fillHeight: true)
        XCTAssertEqual(maxPan, 500.0 * 2100 / 900 - 1000, accuracy: 0.01)  // ≈166.7
        // 平移到一半
        let rHalf = ContentLayout.rect(videoSize: v, bounds: bounds, fillHeight: true, panX: maxPan / 2)
        XCTAssertEqual(rHalf.minX, -maxPan / 2, accuracy: 0.01)
        // 超过 max 被夹住
        let rOver = ContentLayout.rect(videoSize: v, bounds: bounds, fillHeight: true, panX: maxPan + 999)
        XCTAssertEqual(rOver.minX, -maxPan, accuracy: 0.01)
        // 负 panX 被夹到 0
        let rNeg = ContentLayout.rect(videoSize: v, bounds: bounds, fillHeight: true, panX: -50)
        XCTAssertEqual(rNeg.minX, 0, accuracy: 0.01)
    }

    func test_fillHeight_narrowContent_centeredNoPan() {
        // 高瘦内容(填高后比窗口窄)→ 居中、maxPan=0。
        let v = CGSize(width: 600, height: 900)  // 填高 500 → 宽 333.3 < 1000
        let r = ContentLayout.rect(videoSize: v, bounds: bounds, fillHeight: true, panX: 0)
        XCTAssertEqual(r.height, 500, accuracy: 0.01)
        XCTAssertEqual(r.midX, bounds.midX, accuracy: 0.01)
        XCTAssertEqual(ContentLayout.maxPanX(videoSize: v, bounds: bounds, fillHeight: true), 0, accuracy: 0.01)
    }

    // MARK: - 归一化(正变换 + 反演)

    func test_normalize_corners_letterbox() {
        let v = CGSize(width: 1000, height: 500)  // 与窗口同比 → 内容铺满 bounds
        let r = ContentLayout.rect(videoSize: v, bounds: bounds, fillHeight: false, panX: 0)
        // 左上角(视图左上 = y 最大)→ (0,0)
        let tl = ContentLayout.normalize(point: CGPoint(x: r.minX, y: r.maxY), content: r)
        XCTAssertEqual(tl!.nx, 0, accuracy: 1e-9)
        XCTAssertEqual(tl!.ny, 0, accuracy: 1e-9)
        // 右下角(视图右下 = y 最小)→ (1,1)
        let br = ContentLayout.normalize(point: CGPoint(x: r.maxX, y: r.minY), content: r)
        XCTAssertEqual(br!.nx, 1, accuracy: 1e-9)
        XCTAssertEqual(br!.ny, 1, accuracy: 1e-9)
        // 中心 → (0.5,0.5)
        let c = ContentLayout.normalize(point: CGPoint(x: r.midX, y: r.midY), content: r)
        XCTAssertEqual(c!.nx, 0.5, accuracy: 1e-9)
        XCTAssertEqual(c!.ny, 0.5, accuracy: 1e-9)
    }

    func test_normalize_yIsFlipped_topOfViewMapsToNyZero() {
        let v = CGSize(width: 1000, height: 500)
        let r = ContentLayout.rect(videoSize: v, bounds: bounds, fillHeight: false, panX: 0)
        // 视图顶部(y 大)应映射到 ny≈0(远端屏幕顶)。
        let top = ContentLayout.normalize(point: CGPoint(x: r.midX, y: r.maxY - 1), content: r)!
        let bottom = ContentLayout.normalize(point: CGPoint(x: r.midX, y: r.minY + 1), content: r)!
        XCTAssertLessThan(top.ny, 0.01)
        XCTAssertGreaterThan(bottom.ny, 0.99)
    }

    func test_normalize_outsideContent_returnsNil() {
        let v = CGSize(width: 1000, height: 1000)  // 左右黑边
        let r = ContentLayout.rect(videoSize: v, bounds: bounds, fillHeight: false, panX: 0)  // 居中 500 宽
        // 点在左黑边里(x < content.minX)→ nil
        XCTAssertNil(ContentLayout.normalize(point: CGPoint(x: r.minX - 5, y: r.midY), content: r))
        // 点在内容内 → 非 nil
        XCTAssertNotNil(ContentLayout.normalize(point: CGPoint(x: r.midX, y: r.midY), content: r))
    }

    /// 平移后点击映射:同一屏幕点,panX 不同 → nx 不同(内容在底下滚动了),且仍正确反演。
    func test_normalize_underPan_mapsToShiftedContent() {
        let v = CGSize(width: 2100, height: 900)
        let maxPan = ContentLayout.maxPanX(videoSize: v, bounds: bounds, fillHeight: true)
        let screenPoint = CGPoint(x: 500, y: 250)  // 窗口中点

        let r0 = ContentLayout.rect(videoSize: v, bounds: bounds, fillHeight: true, panX: 0)
        let n0 = ContentLayout.normalize(point: screenPoint, content: r0)!
        let rMax = ContentLayout.rect(videoSize: v, bounds: bounds, fillHeight: true, panX: maxPan)
        let nMax = ContentLayout.normalize(point: screenPoint, content: rMax)!

        XCTAssertGreaterThan(nMax.nx, n0.nx, "右移内容后,同一屏幕点应对应更靠右的远端坐标")
        // 反演校验:nx 应等于 (screenX - content.minX)/width
        XCTAssertEqual(n0.nx, Double((screenPoint.x - r0.minX) / r0.width), accuracy: 1e-9)
        XCTAssertEqual(nMax.nx, Double((screenPoint.x - rMax.minX) / rMax.width), accuracy: 1e-9)
    }

    // MARK: - 退化输入

    func test_zeroVideoSize_returnsEmptyRectAndNoCrash() {
        let r = ContentLayout.rect(videoSize: .zero, bounds: bounds, fillHeight: true, panX: 10)
        XCTAssertEqual(r, .zero)
        XCTAssertNil(ContentLayout.normalize(point: CGPoint(x: 1, y: 1), content: .zero))
        XCTAssertEqual(ContentLayout.maxPanX(videoSize: .zero, bounds: bounds, fillHeight: true), 0)
    }
}
