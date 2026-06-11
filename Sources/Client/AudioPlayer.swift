import AVFoundation

/// 远端系统音频播放 —— 收到的交织 Float32 `AudioPacket` 反交织进 `AVAudioPCMBuffer`,
/// 排入 `AVAudioPlayerNode` 顺序播放。
///
/// 三个稳健性要点(对抗审查后补上):
/// 1) **起播抖动缓冲**:攒够 `startDelay`(≈视频 PreviewView 的 0.06s 呈现延迟)才开播 →
///    既抗网络抖动,又让音频大致与晚 60ms 呈现的视频对齐(不再领先一截、对口型不飘)。
/// 2) **过载丢弃**:TCP 卡顿恢复会 burst 回灌一批帧,纯追加排播会让延迟阶梯式累积、永不收敛。
///    排队时长超 `maxQueue` 即冲掉重攒,吸收单向漂移。
/// 3) **断线重置**:重连前必须清空旧队列,否则陈旧声音爆出 + 延迟永久叠加(LAN 也必现)。
///
/// 线程:play() 来自 ClientConnection 串行队列;scheduleBuffer 的 completionHandler 在引擎内部线程,
/// 故 `queuedFrames` 用锁保护(其余状态仅 conn 队列访问)。
final class AudioPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    /// AAC 解码器(收到 AAC 包时按格式惰性建/换)。PCM 包不用它。
    private var codec: AACCodec?
    private var attached = false
    private var primed = false              // 是否已攒够初始缓冲并开播(仅 conn 队列访问)

    private var queuedFrames = 0            // 已排队未播完的帧数(跨线程,锁保护)
    private let lock = NSLock()

    /// 起播缓冲 ≈ 视频 PreviewView.bufferDelay(0.06s),保持音画大致同步。
    private static let startDelay = 0.06
    /// 排队上限:超过即判为在累积漂移,冲掉重攒。
    private static let maxQueue = 0.25

    /// 播放一帧(AAC 解码或 PCM 直读)。
    func play(_ pkt: AudioPacket) {
        guard pkt.channels > 0, pkt.frameCount > 0,
              let fmt = ensureFormat(sampleRate: Double(pkt.sampleRate),
                                     channels: AVAudioChannelCount(pkt.channels)) else { return }

        let buffer: AVAudioPCMBuffer?
        switch pkt.codec {
        case .aac:
            if codec == nil || codec!.sampleRate != fmt.sampleRate || codec!.channels != fmt.channelCount {
                codec = AACCodec(sampleRate: fmt.sampleRate, channels: fmt.channelCount, interleavedInput: false)
            }
            buffer = codec?.decode(pkt.payload)
        case .pcmFloat32:
            buffer = makeBuffer(pkt, format: fmt)
        }
        guard let buffer, buffer.frameLength > 0 else { return }
        let rate = fmt.sampleRate
        let frames = Int(buffer.frameLength)   // 用解码后真实帧数(AAC=1024;PCM=frameCount)

        // 过载保护:积压超阈值 → 冲掉重攒(吸收 burst 回灌造成的单向延迟漂移)。
        lock.lock(); let queuedSec = Double(queuedFrames) / rate; lock.unlock()
        if queuedSec > AudioPlayer.maxQueue {
            player.stop()
            lock.lock(); queuedFrames = 0; lock.unlock()
            primed = false
        }

        lock.lock(); queuedFrames += frames; let nowSec = Double(queuedFrames) / rate; lock.unlock()
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.queuedFrames = max(0, self.queuedFrames - frames); self.lock.unlock()
        }

        // 攒够 startDelay 才开播;已开播则保持。
        if primed {
            if !player.isPlaying { player.play() }
        } else if nowSec >= AudioPlayer.startDelay {
            primed = true
            player.play()
        }
    }

    /// 断线/重连时调用:清空旧队列,避免陈旧声音 + 延迟累积。下一帧会重新攒缓冲起播。
    func reset() {
        player.stop()
        lock.lock(); queuedFrames = 0; lock.unlock()
        primed = false
    }

    func stop() {
        player.stop()
        engine.stop()
    }

    /// 确保引擎图为目标格式;已是则复用,变了则重建(重建前清队列)。
    private func ensureFormat(sampleRate: Double, channels: AVAudioChannelCount) -> AVAudioFormat? {
        if let f = format, f.sampleRate == sampleRate, f.channelCount == channels { return f }
        guard let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                    channels: channels, interleaved: false) else { return nil }
        player.stop()                         // 跨格式不残留旧队列
        lock.lock(); queuedFrames = 0; lock.unlock()
        primed = false
        if engine.isRunning { engine.stop() }
        if !attached { engine.attach(player); attached = true }
        engine.connect(player, to: engine.mainMixerNode, format: f)
        do { try engine.start() } catch {
            NSLog("[直控] 音频引擎启动失败: \(error)")
            return nil
        }
        format = f
        return f
    }

    /// 交织 Float32 Data(PCM 包)→ 非交织 AVAudioPCMBuffer。
    private func makeBuffer(_ pkt: AudioPacket, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = Int(pkt.frameCount), channels = Int(pkt.channels)
        guard pkt.payload.count == frames * channels * 4,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let dst = buf.floatChannelData else { return nil }
        buf.frameLength = AVAudioFrameCount(frames)
        pkt.payload.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Float.self)
            for f in 0..<frames {
                let base = f * channels
                for c in 0..<channels { dst[c][f] = src[base + c] }
            }
        }
        return buf
    }
}
