import Foundation

struct FrameRateCalculator {
    private var timestamps: [CFTimeInterval] = []
    private let window: CFTimeInterval
    init(window: CFTimeInterval = 1.0) { self.window = window }
    mutating func recordFrame(at time: CFTimeInterval) {
        timestamps.append(time)
        let cutoff = time - window
        timestamps.removeAll { $0 < cutoff }
    }
    var sampleCount: Int { timestamps.count }
    var fps: Double {
        guard let first = timestamps.first, let last = timestamps.last, last > first else { return 0 }
        return Double(timestamps.count - 1) / (last - first)
    }
}
