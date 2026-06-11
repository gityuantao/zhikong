import XCTest
import AVFoundation
@testable import ZhiKong

final class AACCodecTests: XCTestCase {
    private func sineBuffer(_ format: AVAudioFormat, frames: Int, freq: Double, phase: inout Double) -> AVAudioPCMBuffer {
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        let ch = Int(format.channelCount)
        let inc = 2 * Double.pi * freq / format.sampleRate
        for f in 0..<frames {
            let v = Float(sin(phase)); phase += inc
            for c in 0..<ch { buf.floatChannelData![c][f] = v }
        }
        return buf
    }

    /// 编码 → 解码往返:产出可解的 1024 帧 PCM、有能量(非静音)、样本有限。验证整条 AAC 管线打通。
    func test_aac_encodeDecode_roundTrip_producesPlausiblePCM() throws {
        let codec = try XCTUnwrap(AACCodec(sampleRate: 48000, channels: 2, interleavedInput: false))
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        var phase = 0.0
        var aacPackets: [Data] = []
        for _ in 0..<20 {   // 喂 ~20 块越过 priming
            aacPackets.append(contentsOf: codec.encode(sineBuffer(fmt, frames: 1024, freq: 440, phase: &phase)))
        }
        XCTAssertFalse(aacPackets.isEmpty, "编码应产出 AAC 包")
        for p in aacPackets {
            XCTAssertGreaterThan(p.count, 0)
            XCTAssertLessThan(p.count, 8192, "AAC 包应远小于等量未压缩 PCM(1024*2*4)")
        }

        let dec = try XCTUnwrap(AACCodec(sampleRate: 48000, channels: 2, interleavedInput: false))
        var decodedAny = false
        var maxAbs: Float = 0
        for p in aacPackets {
            guard let out = dec.decode(p) else { continue }
            XCTAssertEqual(out.frameLength, 1024)
            XCTAssertEqual(out.format.channelCount, 2)
            let ch0 = out.floatChannelData![0]
            for i in 0..<Int(out.frameLength) {
                XCTAssertTrue(ch0[i].isFinite)
                maxAbs = max(maxAbs, abs(ch0[i]))
            }
            decodedAny = true
        }
        XCTAssertTrue(decodedAny, "应能解出 PCM")
        XCTAssertGreaterThan(maxAbs, 0.05, "440Hz 正弦解码后应有明显能量")
    }

    /// 压缩比应明显 > 8x(未压缩 8192 字节/1024帧立体声 → AAC ~数百字节)。
    func test_aac_compressionRatio_isLarge() throws {
        let codec = try XCTUnwrap(AACCodec(sampleRate: 48000, channels: 2, interleavedInput: false))
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        var phase = 0.0, totalAAC = 0, packets = 0
        for _ in 0..<40 {
            for p in codec.encode(sineBuffer(fmt, frames: 1024, freq: 440, phase: &phase)) { totalAAC += p.count; packets += 1 }
        }
        let packetsCount = try XCTUnwrap(packets > 0 ? packets : nil)
        let pcmBytes = packetsCount * 1024 * 2 * 4
        let ratio = Double(pcmBytes) / Double(totalAAC)
        XCTAssertGreaterThan(ratio, 8.0, "压缩比应 > 8x,实际 \(ratio)")
    }
}
