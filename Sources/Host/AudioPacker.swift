import AVFoundation
import CoreMedia

/// 把 SCStream 的音频 `CMSampleBuffer` 打成网络就绪的 `AudioPacket`。
///
/// 默认 **AAC 压缩**(~128kbps,省外网带宽);`useAAC=false` 退回**未压缩交织 Float32**(局域网/兜底,
/// 与历史一致、最稳)。一个音频 CMSampleBuffer 经 AAC 编码可能产出 0..N 个包(每包 1024 样本),故返回数组。
///
/// ⚠️ PCM 提取不假定布局:SCStream 一般给**非交织(planar)Float32**,个别机型/系统给**交织**;按
/// `format.isInterleaved` 分流(交织缓冲 chans[1] 越界会爆音/崩)。非 Float32 直接记日志丢弃(便于真机定位无声)。
///
/// 有状态(AAC 编码器跨帧留存尾部样本),只在捕获音频队列(串行)调用,无需加锁。
final class AudioPacker {
    private let useAAC: Bool
    private var codec: AACCodec?
    private var loggedFormat = false

    init(useAAC: Bool = true) { self.useAAC = useAAC }

    func pack(_ sb: CMSampleBuffer) -> [AudioPacket] {
        guard sb.isValid,
              let fmtDesc = CMSampleBufferGetFormatDescription(sb),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc) else {
            NSLog("[直控][音频] pack 失败:无效样本/无格式描述")
            return []
        }
        let asbd = asbdPtr.pointee
        if !loggedFormat {
            loggedFormat = true
            NSLog("[直控][音频] 首帧 ASBD: %.0fHz ch=%u bits=%u flags=0x%x codec=%@",
                  asbd.mSampleRate, asbd.mChannelsPerFrame, asbd.mBitsPerChannel, asbd.mFormatFlags,
                  useAAC ? "AAC" : "PCM")
        }
        let frames = Int(CMSampleBufferGetNumSamples(sb))
        let channels = Int(asbd.mChannelsPerFrame)
        guard frames > 0, channels > 0 else { return [] }

        let srcFormat = AVAudioFormat(cmAudioFormatDescription: fmtDesc)   // 非可失败初始化器
        guard let pcm = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(frames)) else {
            NSLog("[直控][音频] pack 失败:AVAudioPCMBuffer 建立失败")
            return []
        }
        pcm.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sb, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        guard status == noErr else {
            NSLog("[直控][音频] pack 失败:拷 PCM status=%d", status)
            return []
        }
        guard srcFormat.commonFormat == .pcmFormatFloat32 else {
            NSLog("[直控][音频] pack 失败:非 Float32(commonFormat=%ld),本帧丢弃", srcFormat.commonFormat.rawValue)
            return []
        }

        let pts = Int64(CMSampleBufferGetPresentationTimeStamp(sb).seconds * 1_000_000)
        let rate = UInt32(asbd.mSampleRate.rounded())

        if useAAC {
            // 复用/构建匹配当前格式的 AAC 编码器(直接喂捕获的 PCM buffer)。
            if codec == nil || codec!.sampleRate != srcFormat.sampleRate || codec!.channels != AVAudioChannelCount(channels) {
                codec = AACCodec(sampleRate: srcFormat.sampleRate,
                                   channels: AVAudioChannelCount(channels),
                                   interleavedInput: srcFormat.isInterleaved)
            }
            guard let codec else { return [] }
            return codec.encode(pcm).map {
                AudioPacket(pts: pts, sampleRate: rate, channels: UInt8(channels),
                            codec: .aac, frameCount: UInt32(AACCodec.framesPerPacket), payload: $0)
            }
        } else {
            guard let interleaved = AudioPacker.toInterleavedFloat32(pcm, channels: channels, frames: frames) else { return [] }
            return [AudioPacket(pts: pts, sampleRate: rate, channels: UInt8(channels),
                                codec: .pcmFloat32, frameCount: UInt32(frames), payload: interleaved)]
        }
    }

    /// 统一产出交织 Float32 Data,按布局分流:已交织→整段拷贝;非交织→反交织。
    private static func toInterleavedFloat32(_ buf: AVAudioPCMBuffer, channels: Int, frames: Int) -> Data? {
        let byteCount = frames * channels * 4
        if buf.format.isInterleaved {
            let abl = buf.audioBufferList.pointee
            guard abl.mNumberBuffers >= 1, let mData = abl.mBuffers.mData else {
                NSLog("[直控][音频] 交织帧无数据指针,丢弃"); return nil
            }
            return Data(bytes: mData, count: min(byteCount, Int(abl.mBuffers.mDataByteSize)))
        } else {
            guard let chans = buf.floatChannelData else {
                NSLog("[直控][音频] 非交织但无 floatChannelData,丢弃"); return nil
            }
            var out = Data(count: byteCount)
            out.withUnsafeMutableBytes { raw in
                let dst = raw.bindMemory(to: Float.self)
                for f in 0..<frames {
                    let base = f * channels
                    for c in 0..<channels { dst[base + c] = chans[c][f] }
                }
            }
            return out
        }
    }
}
