import CoreMedia
import Foundation

/// `VideoFramePacket → CMSampleBuffer` 重建(客户端解码侧也复用)。
///
/// 关键帧用携带的 VPS/SPS/PPS 经 `CMVideoFormatDescriptionCreateFromHEVCParameterSets`
/// (NALUnitHeaderLength=4)建 format description 并缓存;非关键帧复用上次缓存的 format description。
/// NAL 数据为 AVCC 4 字节长度前缀,可直接交给 AVSampleBufferDisplayLayer 硬解。
final class HEVCSampleBufferBuilder {
    private var formatDescription: CMFormatDescription?

    func build(from packet: VideoFramePacket) -> CMSampleBuffer? {
        // 1) 关键帧:用参数集(重)建 format description 并缓存。
        if !packet.parameterSets.isEmpty {
            if let fmt = makeFormatDescription(from: packet.parameterSets) {
                formatDescription = fmt
            }
        }
        guard let fmt = formatDescription else { return nil }

        // 2) 把 NAL 数据拷入一块 CoreMedia 自有的内存块。
        //    关键:绝不用 kCFAllocatorNull 直接别名 `packet.nalData` 的缓冲——那块内存随
        //    Data 释放即失效,会造成 use-after-free。这里先分配空块(memoryBlock: nil +
        //    kCFAllocatorDefault),再 ReplaceDataBytes 把字节"拷进去",使数据生命周期
        //    随 CMBlockBuffer(进而随返回的 CMSampleBuffer)而非局部 Data。
        let length = packet.nalData.count
        var block: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,                 // 让 CoreMedia 自己分配,持有所有权
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: kCMBlockBufferAssureMemoryNowFlag, // 立刻实际分配底层内存,便于随后拷入
            blockBufferOut: &block)
        guard createStatus == kCMBlockBufferNoErr, let block else { return nil }

        // 把字节拷入(从 Data 的临时指针拷到 CMBlockBuffer 自有内存;之后 Data 释放无影响)。
        let copyStatus = packet.nalData.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else {
                // length == 0 的极端情况:无字节需拷贝,视为成功。
                return length == 0 ? kCMBlockBufferNoErr : kCMBlockBufferBlockAllocationFailedErr
            }
            return CMBlockBufferReplaceDataBytes(
                with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        // 3) 组装 CMSampleBuffer,带 PTS。
        var sample: CMSampleBuffer?
        let pts = CMTime(value: packet.pts, timescale: 1_000_000)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sizeArr = [length]
        let sampleStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: fmt, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &sizeArr, sampleBufferOut: &sample)
        // 不再打 DisplayImmediately:改由 PreviewView 的 AVSampleBufferRenderSynchronizer
        // 时基按 PTS 匀速调度,用缓冲吸收网络抖动(见 PreviewView)。帧带真实 PTS 即可。
        guard sampleStatus == noErr, let sample else { return nil }
        return sample
    }

    private func makeFormatDescription(from parameterSets: [Data]) -> CMFormatDescription? {
        // 把每个参数集的字节起始指针收集成 C 数组。withUnsafeBytes 的指针只在闭包内有效,
        // 因此整个 Create 调用必须在嵌套闭包内完成,避免悬垂指针。
        return withParameterSetPointers(parameterSets) { pointers, sizes in
            var fmt: CMFormatDescription?
            let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: parameterSets.count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                extensions: nil,
                formatDescriptionOut: &fmt)
            return status == noErr ? fmt : nil
        }
    }

    /// 安全地把 `[Data]` 暴露为 `(指针数组, 大小数组)`,所有指针在 body 执行期间均有效。
    private func withParameterSetPointers(
        _ sets: [Data],
        _ body: (_ pointers: [UnsafePointer<UInt8>], _ sizes: [Int]) -> CMFormatDescription?
    ) -> CMFormatDescription? {
        let sizes = sets.map { $0.count }

        func recurse(_ index: Int, _ acc: [UnsafePointer<UInt8>]) -> CMFormatDescription? {
            if index == sets.count {
                return body(acc, sizes)
            }
            return sets[index].withUnsafeBytes { raw -> CMFormatDescription? in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
                return recurse(index + 1, acc + [base])
            }
        }
        return recurse(0, [])
    }
}
