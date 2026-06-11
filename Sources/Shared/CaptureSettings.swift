import ScreenCaptureKit
import CoreMedia
import CoreVideo

struct CaptureSettings {
    var width: Int
    var height: Int
    var fps: Int
    var showsCursor: Bool
    /// 是否同时抓系统音频(被控机正在播放的声音)。需屏幕录制权限(无需额外音频权限)。
    var capturesAudio: Bool
    var audioSampleRate: Int
    var audioChannels: Int
    init(width: Int, height: Int, fps: Int = 60, showsCursor: Bool = true,
         capturesAudio: Bool = true, audioSampleRate: Int = 48000, audioChannels: Int = 2) {
        self.width = width; self.height = height; self.fps = fps; self.showsCursor = showsCursor
        self.capturesAudio = capturesAudio
        self.audioSampleRate = audioSampleRate
        self.audioChannels = audioChannels
    }
    func makeStreamConfiguration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = showsCursor
        config.queueDepth = 6
        if capturesAudio {
            config.capturesAudio = true
            config.sampleRate = audioSampleRate
            config.channelCount = audioChannels
            // 不排除本进程音频:被控机上任意 App 的声音都要传过去。
            config.excludesCurrentProcessAudio = false
        }
        return config
    }
}
