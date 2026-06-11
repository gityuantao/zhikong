import VideoToolbox
import CoreMedia

/// VideoToolbox HEVC 硬件编码封装。
///
/// 输入 NV12 `CVPixelBuffer`,输出网络就绪的 `VideoFramePacket`(关键帧携带 VPS/SPS/PPS)。
/// 低延迟实时档:RealTime + 关闭帧重排,保证编码即出帧、PTS 单调。
final class HEVCEncoder {
    var onPacket: ((VideoFramePacket) -> Void)?

    /// 平均码率(bps)。局域网默认 20Mbps;外网由 AppDelegate 在 setup 前调低(默认 4Mbps)以适配蜂窝/上行受限。
    var bitRate: Int = 20_000_000
    /// 关键帧最大间隔(帧)。外网调小(如 30)→ 丢帧/新连入后更快恢复(代价是码率占用略升)。
    var maxKeyFrameInterval: Int = 120

    /// 会话与其尺寸。encode 在捕获队列、stop/updateBitRate 可能在主线程 → 用锁保护属性存取
    /// (拿到的 session 引用因 ARC retain 不会 UAF;已失效会话上的 VT 调用只会返回错误码,不崩)。
    private let sessionLock = NSLock()
    private var session: VTCompressionSession?
    private var sessionWidth = 0
    private var sessionHeight = 0

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, forceKeyframe: Bool = false) {
        let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
        sessionLock.lock()
        // 分辨率变化(如被控机改了显示器分辨率)→ 旧会话尺寸不符,重建。
        if let s = session, sessionWidth != w || sessionHeight != h {
            VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(s)
            session = nil
            NSLog("[直控] 输入尺寸变化 %dx%d → %dx%d,重建编码器", sessionWidth, sessionHeight, w, h)
        }
        if session == nil { setup(width: w, height: h) }
        let session = self.session
        sessionLock.unlock()
        guard let session else { return }
        // 静止重发时强制关键帧:新连入的控制端无需等下一个关键帧即可解出画面。
        let frameProps: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
            duration: .invalid, frameProperties: frameProps, infoFlagsOut: nil
        ) { [weak self] status, _, sbuf in
            guard status == noErr, let sbuf, let self else { return }
            self.handleEncoded(sbuf)
        }
    }

    func stop() {
        sessionLock.lock()
        let s = session
        session = nil
        sessionLock.unlock()
        guard let s else { return }
        VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(s)
    }

    /// 在**活动会话上**动态改码率(自适应码率用,无需重建会话)。线程安全(VTSessionSetProperty)。
    func updateBitRate(_ bps: Int) {
        sessionLock.lock()
        bitRate = bps
        let session = self.session
        sessionLock.unlock()
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bps as CFNumber)
        let cap = bps + bps / 2
        let limits = [cap / 8, 1] as CFArray
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
    }

    /// 仅在持有 `sessionLock` 时调用(由 encode 调)。
    private func setup(width: Int, height: Int) {
        var s: VTCompressionSession?
        // 低延迟码控(EnableLowLatencyRateControl):苹果为实时/会议场景设计,
        // 显著降低编码缓冲与延迟。放在 encoderSpecification 里、建会话时指定。
        let encoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue as Any
        ]
        let createStatus = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_HEVC, encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard createStatus == noErr, let s else {
            NSLog("[直控] VTCompressionSessionCreate 失败: \(createStatus)")
            return
        }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        // 不让编码器攒帧:编一帧立即出一帧,去掉管线缓冲带来的额外延迟。
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        // 实时优先,不为省电牺牲延迟。
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaximizePowerEfficiency, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: maxKeyFrameInterval as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bitRate as CFNumber)
        // 外网低码率时,给数据率上限做硬约束(避免突发关键帧瞬时撑爆窄链路)。
        let cap = bitRate + bitRate / 2  // 1.5x 容忍
        let limits = [cap / 8, 1] as CFArray   // [字节数/秒, 1秒窗口]
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s
        sessionWidth = width
        sessionHeight = height
        NSLog("[直控] 编码器就绪 %dx%d 低延迟码控", width, height)
    }

    private func handleEncoded(_ sbuf: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sbuf) else { return }
        var lengthAtOffset = 0, totalLength = 0
        var dataPtr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            block, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength, dataPointerOut: &dataPtr) == noErr,
            let dataPtr, totalLength > 0 else { return }
        // CMBlockBuffer 可能由多段不连续内存组成:dataPtr 只保证 lengthAtOffset 字节连续。
        // 直接按 totalLength 读会越界 → 仅在整块连续时走零拷贝指针,否则逐段拷出。
        let nalData: Data
        if lengthAtOffset == totalLength {
            nalData = Data(bytes: dataPtr, count: totalLength)
        } else {
            var copied = Data(count: totalLength)
            let ok = copied.withUnsafeMutableBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return false }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: totalLength,
                                                  destination: base) == kCMBlockBufferNoErr
            }
            guard ok else { return }
            nalData = copied
        }

        let notSync = (CMSampleBufferGetSampleAttachmentsArray(sbuf, createIfNecessary: false) as? [[CFString: Any]])?
            .first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKeyframe = !notSync

        var paramSets: [Data] = []
        if isKeyframe, let fmt = CMSampleBufferGetFormatDescription(sbuf) {
            var count = 0
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    fmt, parameterSetIndex: i,
                    parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                    let ptr {
                    paramSets.append(Data(bytes: ptr, count: size))
                }
            }
        }
        let ptsMicros = Int64(CMSampleBufferGetPresentationTimeStamp(sbuf).seconds * 1_000_000)
        onPacket?(VideoFramePacket(pts: ptsMicros, isKeyframe: isKeyframe, parameterSets: paramSets, nalData: nalData))
    }
}
