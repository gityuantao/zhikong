import ScreenCaptureKit
import CoreMedia

enum CaptureError: Error { case noDisplay }

final class ScreenCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?
    /// 系统音频帧回调(被控机正在播放的声音)。在独立的音频队列上触发,不与视频争用。
    var onAudioSampleBuffer: ((CMSampleBuffer) -> Void)?
    var onError: ((Error) -> Void)?

    /// 捕获分辨率长边上限(像素)。外网模式下设 ~1920:把分辨率降下来,**同码率下画质显著更好**
    /// (4Mbps 编 1080p 比编 5K 清晰得多)。nil = 原生分辨率(局域网默认)。
    /// 坐标全程按 0..1 归一化,降分辨率不影响远控映射。
    var maxDimension: Int?

    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "com.zhikong.capture.samples")
    private let audioQueue = DispatchQueue(label: "com.zhikong.capture.audio")

    /// 按长边上限等比缩放出捕获分辨率(HEVC 要求偶数边,向下取偶)。maxDimension 为空或屏幕本就更小 → 原样。
    static func outputSize(displayW: Int, displayH: Int, maxDimension: Int?) -> (width: Int, height: Int) {
        guard let maxDim = maxDimension, maxDim > 0 else { return (displayW, displayH) }
        let longEdge = max(displayW, displayH)
        guard longEdge > maxDim else { return (displayW, displayH) }
        let scale = Double(maxDim) / Double(longEdge)
        func even(_ x: Double) -> Int { let v = Int(x.rounded()); return max(2, v - (v % 2)) }
        return (even(Double(displayW) * scale), even(Double(displayH) * scale))
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = DisplaySelector.main(from: content.displays, preferring: CGMainDisplayID()) else {
            throw CaptureError.noDisplay
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let (w, h) = ScreenCaptureEngine.outputSize(displayW: display.width, displayH: display.height, maxDimension: maxDimension)
        if w != display.width { NSLog("[直控] 外网降分辨率 %dx%d → %dx%d", display.width, display.height, w, h) }
        // showsCursor=false:画面里不含系统光标。Client 端自绘合成光标(零延迟、永远准确),
        // 避免"被注入移动时系统不渲染光标 → 看不到指针"以及双光标问题。
        let settings = CaptureSettings(width: w, height: h, fps: 60, showsCursor: false)
        let config = settings.makeStreamConfiguration()
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        // 音频输出:失败不致命(没声音也能远控),仅记录。
        if config.capturesAudio {
            do { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue) }
            catch { NSLog("[直控] 添加音频输出失败(继续无声): \(error)") }
        }
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        stream?.stopCapture { _ in }
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let statusRaw = attachments.first?[.status] as? Int,
                  let status = SCFrameStatus(rawValue: statusRaw),
                  status == .complete else { return }
            onSampleBuffer?(sampleBuffer)
        case .audio:
            onAudioSampleBuffer?(sampleBuffer)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }
}
