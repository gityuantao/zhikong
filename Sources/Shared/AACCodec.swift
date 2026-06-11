import AVFoundation

/// 系统音频 **AAC-LC 编解码**(macOS 原生 AVAudioConverter,零第三方依赖)。
/// Host 编(Float32 PCM → AAC),Client 解(AAC → Float32 PCM)。把未压缩 ~3Mbps 降到 ~128kbps,
/// 给外网视频腾带宽。
///
/// 约定:AAC-LC,**1024 样本/包**;两端用**完全相同**的格式参数(采样率/声道)构造 AVAudioFormat,
/// 故解码端无需传 magic cookie 即可解(AAC-LC 标准配置由参数完全确定)。有损:往返非 bit-exact,
/// 但听感近透明。优先级:正确稳定 > 极致压缩。
///
/// 线程:编码只在 Host 捕获音频队列(串行)用;解码只在 Client 连接队列(串行)用。各自单线程,无需加锁。
final class AACCodec {
    let sampleRate: Double
    let channels: AVAudioChannelCount
    /// AAC 每包样本数(AAC-LC 恒为 1024)。
    static let framesPerPacket = 1024

    private let aacFormat: AVAudioFormat
    private let pcmInFormat: AVAudioFormat    // 编码输入 PCM 格式(Host 侧,可交织/非交织)
    private let pcmOutFormat: AVAudioFormat   // 解码输出 PCM 格式(Client 侧,非交织,供 AudioPlayer)
    private let bitRate: Int

    private var encoder: AVAudioConverter?
    private var decoder: AVAudioConverter?

    init?(sampleRate: Double, channels: AVAudioChannelCount, interleavedInput: Bool, bitRate: Int = 128_000) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitRate = bitRate
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(AACCodec.framesPerPacket), mBytesPerFrame: 0,
            mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0)
        guard let aac = AVAudioFormat(streamDescription: &asbd),
              let pin = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                      channels: channels, interleaved: interleavedInput),
              let pout = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                       channels: channels, interleaved: false)
        else { return nil }
        self.aacFormat = aac
        self.pcmInFormat = pin
        self.pcmOutFormat = pout
    }

    // MARK: - 编码(Host)

    /// 编码一个 PCM buffer(格式须与构造时的 pcmInFormat 一致)。返回 0..N 个 AAC 包字节(每包 1024 样本)。
    /// AVAudioConverter 跨调用有状态:不足 1024 的尾部样本被内部留存,下次补齐;首调有 priming 可能返回空——正常。
    func encode(_ pcm: AVAudioPCMBuffer) -> [Data] {
        if encoder == nil {
            encoder = AVAudioConverter(from: pcmInFormat, to: aacFormat)
            encoder?.bitRate = bitRate
        }
        guard let enc = encoder else { return [] }
        let maxPkt = enc.maximumOutputPacketSize > 0 ? enc.maximumOutputPacketSize : 1536
        let out = AVAudioCompressedBuffer(format: aacFormat, packetCapacity: 64, maximumPacketSize: maxPkt)
        var supplied = false
        var err: NSError?
        let status = enc.convert(to: out, error: &err) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true
            outStatus.pointee = .haveData
            return pcm
        }
        if status == .error { if let err { NSLog("[直控][音频] AAC 编码失败: \(err)") }; return [] }
        return extractPackets(out)
    }

    private func extractPackets(_ buf: AVAudioCompressedBuffer) -> [Data] {
        let count = Int(buf.packetCount)
        guard count > 0, let descs = buf.packetDescriptions else { return [] }
        let base = buf.data
        var packets: [Data] = []
        packets.reserveCapacity(count)
        for i in 0..<count {
            let d = descs[i]
            let size = Int(d.mDataByteSize)
            guard size > 0 else { continue }
            packets.append(Data(bytes: base.advanced(by: Int(d.mStartOffset)), count: size))
        }
        return packets
    }

    // MARK: - 解码(Client)

    /// 解码一个 AAC 包 → 非交织 Float32 PCM buffer(供 AudioPlayer)。失败/空返回 nil。
    func decode(_ aac: Data) -> AVAudioPCMBuffer? {
        guard !aac.isEmpty else { return nil }
        if decoder == nil { decoder = AVAudioConverter(from: aacFormat, to: pcmOutFormat) }
        guard let dec = decoder else { return nil }
        let comp = AVAudioCompressedBuffer(format: aacFormat, packetCapacity: 1, maximumPacketSize: aac.count)
        comp.byteLength = UInt32(aac.count)
        comp.packetCount = 1
        aac.withUnsafeBytes { src in
            if let b = src.baseAddress { memcpy(comp.data, b, aac.count) }
        }
        // packetDescriptions 须非 nil 才能让解码器正确按包解析(用 ?. 静默失败=无声),改硬守卫。
        guard let descs = comp.packetDescriptions else { return nil }
        descs.pointee = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(aac.count))
        guard let outPCM = AVAudioPCMBuffer(pcmFormat: pcmOutFormat,
                                            frameCapacity: AVAudioFrameCount(AACCodec.framesPerPacket)) else { return nil }
        var supplied = false
        var err: NSError?
        let status = dec.convert(to: outPCM, error: &err) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true
            outStatus.pointee = .haveData
            return comp
        }
        if status == .error { if let err { NSLog("[直控][音频] AAC 解码失败: \(err)") }; return nil }
        return outPCM.frameLength > 0 ? outPCM : nil
    }
}
