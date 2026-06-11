import AppKit
import AVFoundation
import CoreMedia

/// 视频渲染视图。`AVSampleBufferDisplayLayer` + `AVSampleBufferRenderSynchronizer` 时基播放:
/// 帧带绝对 PTS,靠把时基对齐到 (PTS - targetDelay) 实现"延迟 targetDelay 后按 PTS 匀速显示"的抖动缓冲。
///
/// ## 自适应抖动缓冲 v2(2026-06-10,经对抗审查重做)
/// v1 用"重锚时基"改缓冲被审出会冻结/跳帧且单调爬满不回落。v2 改两条腿:
/// 1) **靠播放速率稳水位(不靠跳时基)**:水位偏低→`rate<1` 轻微放慢蓄水,偏高→`rate>1` 轻微加快泄水。
///    ±3% 速率人眼不可察,且是反馈积分器、稳态零误差收敛到 target,**全程平滑无跳帧无冻结**。
/// 2) **目标自适应,升降同源、抗离群点**:每窗口数"濒临欠载帧数";超阈值→加大 target,整窗零欠载→缩小 target。
///    单帧偶发尖峰不会触发加大,也不会打断缩小通道 → 收敛到"刚好够吸住当前抖动"的最小缓冲。
/// 仅"大扰动(|误差|>200ms,暂停/burst 回灌)"与渲染器失败才硬重锚(罕见,跳一下可接受)。
class PreviewView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var started = false

    /// 远端视频像素尺寸(宽×高),由 `enqueue` 从样本格式描述自动跟踪。.zero=尚无画面。
    /// 内容矩形与点击归一化都以它为准(`ContentLayout`)。
    private(set) var videoSize: CGSize = .zero

    /// 内容布局模式:false=letterbox 完整显示(Host 预览默认);true=填满高度、超宽溢出+可横向平移(Client)。
    var fillHeight = false
    /// 填高模式下的水平平移量(0…maxPanX),由子类(RemoteControlView)的边缘平移驱动。
    var panX: CGFloat = 0 { didSet { if panX != oldValue { applyContentLayout() } } }

    private var targetDelay = Adaptive.start
    private var currentRate: Float = 1.0
    private var framesInWindow = 0
    private var underrunInWindow = 0

    private enum Adaptive {
        static let start = 0.045           // 起始 45ms:低延迟起步,真欠载才加大(偏向跟手)
        static let minDelay = 0.025        // 下限 25ms
        static let maxDelay = 0.16         // 上限 160ms
        static let underrunFloor = 0.010   // 单帧水位 < 10ms 记一次"濒临欠载"
        static let raiseStep = 0.02
        static let lowerStep = 0.008
        static let windowFrames = 300      // ~5s@60fps 评估窗口
        static let raiseThreshold = 3      // 一窗内濒临欠载 > 3 帧 → 加大(抗偶发尖峰)
        // 速率调节(把水位平滑拉回 target):rate = 1 + gain*(level-target),夹 ±3%。
        static let gain = 0.4
        static let rateMin = 0.97
        static let rateMax = 1.03
        static let hardResync = 0.20       // |level-target| > 200ms → 硬重锚(暂停/burst 复位)
    }

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true     // 填高模式内容会溢出视图两侧,裁剪到 bounds 内
        // frame 已是按宽高比算好的内容矩形,故用 .resize 精确填充该矩形(不再二次 letterbox)。
        displayLayer.videoGravity = .resize
        layer?.addSublayer(displayLayer)
        synchronizer.addRenderer(displayLayer.sampleBufferRenderer)
        applyContentLayout()
    }

    override func layout() {
        super.layout()
        applyContentLayout()
    }

    /// 按当前 videoSize/bounds/fillHeight/panX 放置画面层(子类平移、窗口缩放、首帧到达都会调到)。
    func applyContentLayout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // 布局即时生效,不要隐式动画拖影
        displayLayer.frame = ContentLayout.rect(videoSize: videoSize, bounds: bounds, fillHeight: fillHeight, panX: panX)
        CATransaction.commit()
    }

    /// 清空画面 → 纯黑(无信号/断开时调,避免残留旧帧或花屏)。下一帧会自动重建。
    func clear() {
        displayLayer.sampleBufferRenderer.flush()
        synchronizer.setRate(0, time: .invalid)
        started = false
        videoSize = .zero
        applyContentLayout()   // 尺寸归零 → 画面层归零 → 只剩黑底
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        // 跟踪视频尺寸(供内容矩形/点击归一化);尺寸变化时重新布局。
        if let dims = CMSampleBufferGetFormatDescription(sampleBuffer).map(CMVideoFormatDescriptionGetDimensions) {
            let newSize = CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
            if newSize != videoSize { videoSize = newSize; applyContentLayout() }
        }
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed {
            renderer.flush()
            synchronizer.setRate(0, time: .invalid)
            started = false   // 失败后重锚(保留已学到的 targetDelay)
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !started {
            hardAnchor(to: pts)
            started = true
            resetWindow()
        } else {
            let level = CMTimeGetSeconds(CMTimeSubtract(pts, synchronizer.currentTime()))
            regulate(level: level, pts: pts)
        }
        renderer.enqueue(sampleBuffer)
    }

    /// 速率稳水位 + 窗口自适应目标。
    private func regulate(level: Double, pts: CMTime) {
        let error = level - targetDelay

        // 大扰动:硬重锚快速复位(罕见)。
        if abs(error) > Adaptive.hardResync {
            hardAnchor(to: pts)
            resetWindow()
            return
        }

        // 常态:速率把水位平滑拉回 target(不动锚点 → 不跳帧不冻结)。
        let raw = 1.0 + Adaptive.gain * error
        let rate = Float(min(max(raw, Adaptive.rateMin), Adaptive.rateMax))
        if abs(rate - currentRate) > 0.001 {
            synchronizer.rate = rate
            currentRate = rate
        }

        // 目标自适应(每窗口一次,升降同源:濒临欠载帧计数)。
        framesInWindow += 1
        if level < Adaptive.underrunFloor { underrunInWindow += 1 }
        if framesInWindow >= Adaptive.windowFrames {
            if underrunInWindow > Adaptive.raiseThreshold {
                let new = min(targetDelay + Adaptive.raiseStep, Adaptive.maxDelay)
                if new != targetDelay {
                    targetDelay = new
                    NSLog("[直控][缓冲] ↑ %.0fms(濒欠载 %d/%d 帧)", targetDelay * 1000, underrunInWindow, framesInWindow)
                }
            } else if underrunInWindow == 0, targetDelay > Adaptive.minDelay {
                targetDelay = max(targetDelay - Adaptive.lowerStep, Adaptive.minDelay)
                NSLog("[直控][缓冲] ↓ %.0fms(整窗无欠载)", targetDelay * 1000)
            }
            resetWindow()
        }
    }

    private func resetWindow() {
        framesInWindow = 0
        underrunInWindow = 0
    }

    private func hardAnchor(to pts: CMTime) {
        let start = CMTimeSubtract(pts, CMTime(seconds: targetDelay, preferredTimescale: 1_000_000))
        synchronizer.setRate(1.0, time: start)
        currentRate = 1.0
    }
}
