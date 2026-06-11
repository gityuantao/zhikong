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

    private var session: VTCompressionSession?

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, forceKeyframe: Bool = false) {
        if session == nil {
            setup(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        }
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
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    /// 在**活动会话上**动态改码率(自适应码率用,无需重建会话)。线程安全(VTSessionSetProperty)。
    func updateBitRate(_ bps: Int) {
        bitRate = bps
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bps as CFNumber)
        let cap = bps + bps / 2
        let limits = [cap / 8, 1] as CFArray
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
    }

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
        NSLog("[直控] 编码器就绪 %dx%d 低延迟码控", width, height)
    }

    private func handleEncoded(_ sbuf: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sbuf) else { return }
        var lengthAtOffset = 0, totalLength = 0
        var dataPtr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            block, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength, dataPointerOut: &dataPtr) == noErr,
            let dataPtr else { return }
        let nalData = Data(bytes: dataPtr, count: totalLength)

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
