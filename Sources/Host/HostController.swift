import AppKit
import CoreMedia
import CoreVideo

/// Host(被控端)控制器。**小窗口**:只显示远控码 + 「允许远程控制」开关 + 一行连接状态。
/// 不再做本地预览镜像(看自己屏幕没意义,且省去"自己解码自己"的 CPU)。
/// 后台持续:抓屏 → HEVC 编码 →(外网端到端加密)推送给控制端。
///
/// 单 app 架构下由顶层 `AppDelegate`(角色选择)在选「被控端」后 `start()`;非 NSApplicationDelegate。
final class HostController: NSObject {
    private var window: NSWindow!
    private let capture = ScreenCaptureEngine()
    private let encoder = HEVCEncoder()
    private let server = HostServer()
    private let injector = EventInjector()
    /// 音频打包:默认 AAC 压缩(省外网带宽);`ZHIKONG_AUDIO_PCM=1` 退回未压缩 Float32(兜底)。
    private let audioPacker = AudioPacker(useAAC: ProcessInfo.processInfo.environment["ZHIKONG_AUDIO_PCM"] != "1")
    /// 防空闲休眠:Host 作为远控被控端必须常醒(详见 SleepInhibitor)。整个运行期持有。
    private let sleepInhibitor = SleepInhibitor()
    /// 剪贴板双向同步(纯文本)。
    private let clipboardSync = ClipboardSync()
    /// 自适应码率(opt-in:ZHIKONG_ADAPTIVE=1)。nil=固定码率。
    private var adaptive: AdaptiveBitrateController?
    private let frameCountLock = NSLock()
    private var sentFrameCount = 0
    private var lastFeedbackUptime = ProcessInfo.processInfo.systemUptime

    private var captionLabel: NSTextField!
    private var codeLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var enableButton: NSButton!
    private var refreshButton: NSButton!
    private var copyHint: NSTextField!
    private var copyHintReset: DispatchWorkItem?
    /// 顶层 AppDelegate 注入:点「切换角色」时停掉本端、回到角色选择窗。
    var onSwitchRole: (() -> Void)?

    /// 当前远控码(动态生成、**持久化**:不每次启动都换,重启沿用上次;只在点「刷新」时换)。
    private var currentRoom = ""
    /// 持久化远控码的 UserDefaults 键(域=bundle id com.zhikong.app)。
    private static let savedRoomKey = "zhikong.hostRoom"
    /// 外网中转配置(若有)。决定服务走中转还是局域网,以及展示的远控码。
    private var relayConfig: RelayConfig?
    /// 局域网模式的端到端口令(可选,ZHIKONG_SECRET / relay.conf 第 2 字段)。配了 → LAN 也加密。
    private var lanSecret: String?
    /// 是否允许被远程控制(开关)。关 → 停止服务,中转上无 Host 在场,连不上。
    private var serving = true
    private var clientConnected = false
    /// 「对端在场」镜像(= serving && clientConnected),供捕获/编码回调线程读 ——
    /// 无人观看时跳过 HEVC/AAC 编码(发送端反正会丢),常驻被控端不再空耗 CPU/电。
    /// 主线程写(refreshStatus)、捕获线程读,锁保护。
    private let peerActiveLock = NSLock()
    private var _peerActive = false
    private var isPeerActive: Bool {
        peerActiveLock.lock(); defer { peerActiveLock.unlock() }; return _peerActive
    }
    private func setPeerActive(_ v: Bool) {
        peerActiveLock.lock()
        let was = _peerActive
        _peerActive = v
        peerActiveLock.unlock()
        // 新观看者上线:下一帧直接编关键帧——活动画面下不用等关键帧间隔(~1s)/静止重发(0.5s),立即出图。
        if v && !was { setForceKeyframeNext() }
    }

    /// 「下一帧强制关键帧」标记 —— Client 的 ZKKR 请求 / 新观看者上线 / 捕获恢复都置它,
    /// 捕获回调编码时消费(置位/消费分别在网络与捕获线程,锁保护)。幂等:多次置位只多编一个关键帧。
    private let keyframeFlagLock = NSLock()
    private var _forceKeyframeNext = false
    private func setForceKeyframeNext() {
        keyframeFlagLock.lock(); _forceKeyframeNext = true; keyframeFlagLock.unlock()
    }
    private func consumeForceKeyframe() -> Bool {
        keyframeFlagLock.lock(); defer { keyframeFlagLock.unlock() }
        let v = _forceKeyframeNext; _forceKeyframeNext = false; return v
    }

    // MARK: - 捕获自愈

    /// 捕获重启的指数退避(秒)。成功后复位;上限 30s。
    private var captureBackoff: TimeInterval = 1
    /// 代号:stop()/切角色时 +1,使所有挂起的重启/迟到的启动结果失效(不再重启已停的捕获)。
    private var captureGeneration = 0

    /// 启动(或恢复)捕获;失败按退避自动重试。SCStream 运行中死掉(显示器深睡、登出、SCK 故障)
    /// 走 onError → 同一条恢复路径。被控端"人在外面连不上只能干瞪眼"的最大单点,必须自愈。
    /// 回调由引擎保证在主线程,与本控制器其余状态同线程。
    private func startCaptureWithRetry() {
        let gen = captureGeneration
        capture.start { [weak self] error in
            guard let self else { return }
            // stop()/切角色已发生 → 迟到的成功要立即拆掉,不能留下幽灵流;迟到的失败直接忽略。
            guard gen == self.captureGeneration else {
                if error == nil { self.capture.stop() }
                return
            }
            if let error {
                NSLog("[直控] 启动捕获失败(可能需授权屏幕录制),稍后重试: \(error)")
                self.scheduleCaptureRestart()
            } else {
                self.captureBackoff = 1
                self.setForceKeyframeNext()   // 恢复后第一帧就是关键帧,Client 立即续上画面
                NSLog("[直控] 捕获已启动/恢复")
            }
        }
    }

    /// 按当前退避调度一次重启(主线程调)。
    private func scheduleCaptureRestart() {
        let gen = captureGeneration
        let delay = captureBackoff
        captureBackoff = min(captureBackoff * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, gen == self.captureGeneration else { return }
            self.startCaptureWithRetry()
        }
    }

    /// 启动被控端(由顶层 AppDelegate 在选角色后调用)。
    func start() {
        let w: CGFloat = 360, h: CGFloat = 234
        let leftX: CGFloat = 22                 // 统一左边距;所有内容与「切换角色」左对齐
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "直控 — 被控端"
        // 🔴 必须置 false:被控端关窗后常驻(Dock 可唤回)。默认 true 会在关窗时释放 window,
        // 之后 showWindow() 访问已释放的 window → objc_retain 野指针崩溃。
        window.isReleasedWhenClosed = false
        guard let content = window.contentView else { return }

        // ‹ 切换角色(左上角,左缘与下方内容精确对齐)
        let back = makeLinkLabel("‹ 切换角色", target: self, action: #selector(switchRoleTapped))
        back.frame = NSRect(x: leftX, y: h - 32, width: 110, height: 18)
        content.addSubview(back)

        // "远控码" / "局域网模式" 标题(左)
        captionLabel = NSTextField(labelWithString: "远控码")
        captionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        captionLabel.textColor = .secondaryLabelColor
        captionLabel.alignment = .left
        captionLabel.frame = NSRect(x: leftX, y: h - 64, width: 200, height: 15)
        content.addSubview(captionLabel)

        // 远控码大字(左,点击复制)
        codeLabel = NSTextField(labelWithString: "—")
        codeLabel.font = .monospacedSystemFont(ofSize: 32, weight: .bold)
        codeLabel.alignment = .left
        codeLabel.frame = NSRect(x: leftX, y: h - 106, width: 214, height: 38)
        codeLabel.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(copyCode)))
        content.addSubview(codeLabel)

        // 刷新远控码(放在远控码右侧,占用横向空间,不挤成一列)
        refreshButton = NSButton(title: "↻ 刷新", target: self, action: #selector(refreshCode))
        refreshButton.bezelStyle = .rounded
        refreshButton.controlSize = .small
        refreshButton.sizeToFit()
        let rbw = max(refreshButton.frame.width, 72)
        refreshButton.frame = NSRect(x: w - leftX - rbw, y: h - 100, width: rbw, height: 26)
        content.addSubview(refreshButton)

        // 复制提示 / 反馈(左,在远控码下方)
        copyHint = NSTextField(labelWithString: "点击远控码可复制")
        copyHint.font = .systemFont(ofSize: 11)
        copyHint.textColor = .tertiaryLabelColor
        copyHint.alignment = .left
        copyHint.frame = NSRect(x: leftX, y: h - 128, width: 220, height: 14)
        content.addSubview(copyHint)

        // 允许远程控制开关(左)
        enableButton = NSButton(checkboxWithTitle: "允许远程控制", target: self, action: #selector(toggleServing(_:)))
        enableButton.state = .on
        enableButton.sizeToFit()
        enableButton.frame = NSRect(x: leftX, y: 56, width: enableButton.frame.width, height: 20)
        content.addSubview(enableButton)

        // 连接状态(左,带圆点)
        statusLabel = NSTextField(labelWithString: "○ 等待连接")
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .left
        statusLabel.frame = NSRect(x: leftX, y: 24, width: w - leftX * 2, height: 18)
        content.addSubview(statusLabel)

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 注入前提:检查/申请辅助功能权限(未授权会弹系统授权面板)。
        injector.ensureAccessibility()
        // 远控常驻:阻止系统/显示器空闲休眠(否则人在外面时 Studio 睡了连不上、捕获停帧)。
        sleepInhibitor.begin(reason: "直控:远程被控服务运行中")

        // 局域网:onClientConnected 即控制端直连;外网中转:它只代表连上了中转,控制端在不在靠 onPeerPresence。
        server.onClientConnected = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.relayConfig == nil { self.clientConnected = true; self.refreshStatus() }
            }
        }
        server.onClientDisconnected = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.relayConfig == nil { self.clientConnected = false; self.refreshStatus() }
            }
        }
        // 外网:中转报来控制端是否在线 → 准确反映"控制端已连接 / 等待连接"。
        server.onPeerPresence = { [weak self] present in
            DispatchQueue.main.async { self?.clientConnected = present; self?.refreshStatus() }
        }
        // 反向通道:收到 Client 输入事件 → 注入到 Studio(CGEventPost 线程安全,无需切主线程)。
        server.onInputEvent = { [weak self] event in self?.injector.inject(event) }

        // 剪贴板双向同步:本机(Studio)复制 → 推给控制端;收到控制端的 → 写入本机(NSPasteboard 须主线程)。
        server.onClipboard = { [weak self] text in
            DispatchQueue.main.async { self?.clipboardSync.applyRemote(text) }
        }
        clipboardSync.onLocalChange = { [weak self] text in self?.server.sendClipboard(text) }
        clipboardSync.start()

        // 自适应码率:Client 每秒上报收帧 fps → 比对本机发帧 fps → 调码率(主线程处理)。
        server.onFeedback = { [weak self] clientFps in
            DispatchQueue.main.async { self?.handleFeedback(clientFps: clientFps) }
        }

        // Client 解不出画面时请求关键帧(ZKKR)→ 下一帧强制 IDR(标记线程安全,无需切主线程)。
        server.onKeyframeRequest = { [weak self] in self?.setForceKeyframeNext() }

        // 外网模式(设了 ZHIKONG_RELAY+ZHIKONG_ROOM)→ 出站连中转;否则走局域网 Bonjour。
        if let relay = RelayConfig.load() {
            relayConfig = relay
            NSLog("[直控] Host 外网模式 → 中转 %@:%d(端到端加密)", relay.host, Int(relay.port))
            if relay.usesFallbackSecret {
                NSLog("[直控] ⚠️ 未设独立端到端口令(relay.conf 第3字段 / ZHIKONG_SECRET),加密退化为房间码派生——防不住能看到握手的链路窃听者。建议两端配同一强口令。")
            }
            // 外网画质(可用 env 调,免重编;改完重启 Host 生效)——默认**原画分辨率 + 7Mbps**(清晰与跟手的折中)。
            //   ZHIKONG_WAN_MAXDIM   分辨率长边上限,0/不设 = 原画;弱网想省流可设 1920/1440
            //   ZHIKONG_WAN_BITRATE  码率 bps(默认 7_000_000);还卡就调低(5000000/4000000),想更清且链路扛得住就调高
            //   ZHIKONG_WAN_KEYFRAME 关键帧间隔帧(默认 60)
            // ⚠️ 取舍:码率是延迟的主因——越高越清晰但越吃带宽,塞满链路会 bufferbloat 拖慢一切(含输入)。
            //    分辨率几乎不影响延迟,只影响"同码率下的清晰度"。编码器有 DataRateLimits(1.5x)硬上限 + 中转慢链路丢帧兜底。
            let env = ProcessInfo.processInfo.environment
            let wanBitrate = env["ZHIKONG_WAN_BITRATE"].flatMap { Int($0) } ?? 7_000_000
            let wanMaxDim = env["ZHIKONG_WAN_MAXDIM"].flatMap { Int($0) } ?? 0
            let wanKey = env["ZHIKONG_WAN_KEYFRAME"].flatMap { Int($0) } ?? 60
            encoder.bitRate = wanBitrate
            encoder.maxKeyFrameInterval = wanKey
            capture.maxDimension = wanMaxDim > 0 ? wanMaxDim : nil   // 0 = 原画分辨率(不降采样)
            NSLog("[直控] 外网画质:%@ + %dMbps", wanMaxDim > 0 ? "长边\(wanMaxDim)" : "原画分辨率", wanBitrate / 1_000_000)
            // 自适应码率(opt-in)。默认 ceiling=起始码率(保护式,只在拥塞时降、不向上探测=无振荡);
            // 设 ZHIKONG_WAN_BITRATE_MAX 才允许网好时向上升到该上限。
            if env["ZHIKONG_ADAPTIVE"] == "1" {
                let floor = env["ZHIKONG_WAN_BITRATE_MIN"].flatMap { Int($0) } ?? 2_000_000
                let ceiling = env["ZHIKONG_WAN_BITRATE_MAX"].flatMap { Int($0) } ?? wanBitrate
                adaptive = AdaptiveBitrateController(start: wanBitrate, floor: floor, ceiling: ceiling)
                NSLog("[直控] 自适应码率开启:起始%dM 下限%dM 上限%dM", wanBitrate/1_000_000, floor/1_000_000, ceiling/1_000_000)
            }
            // 远控码:ZHIKONG_ROOM 设了则用固定码(测试/常驻);否则**持久化**——
            // 沿用上次保存的码(重启不变),首次运行才随机生成并存下。点「刷新」才换。
            if !relay.room.isEmpty {
                currentRoom = relay.room
            } else {
                currentRoom = UserDefaults.standard.string(forKey: Self.savedRoomKey) ?? RoomCode.generate()
                UserDefaults.standard.set(currentRoom, forKey: Self.savedRoomKey)
            }
            relayConfig = relay.with(room: currentRoom)
            captionLabel.stringValue = "远控码"
            codeLabel.stringValue = currentRoom
        } else {
            lanSecret = RelayConfig.loadLANSecret()
            captionLabel.stringValue = lanSecret != nil ? "局域网模式 · 已加密" : "局域网模式"
            codeLabel.font = .systemFont(ofSize: 17, weight: .medium)
            codeLabel.stringValue = "控制端自动发现"
            refreshButton.isHidden = true   // 局域网无远控码,藏刷新
            copyHint.isHidden = true        // 无码可复制
            if lanSecret == nil {
                NSLog("[直控] 局域网未加密(未配口令)。如需加密同网会话:两端设同一 ZHIKONG_SECRET 或 ~/.zhikong/relay.conf 第 2 字段。")
            }
        }
        applyServing()   // 按开关(默认开)启动服务

        // 编码侧:NV12 像素缓冲 → HEVC → VideoFramePacket → 推送。回调在捕获队列。
        // 无人观看(isPeerActive=false)时直接跳过编码——发送端本来就会丢,编了纯属白耗 CPU。
        // 控制端一连上,常规帧/静止重发(≤0.5s,强制关键帧)立即恢复出画面。
        capture.onSampleBuffer = { [weak self] sampleBuffer in
            guard let self, self.isPeerActive,
                  let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            self.encoder.encode(pb, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                                forceKeyframe: self.consumeForceKeyframe())
        }
        // 屏幕静止时低频重发最后一帧(强制关键帧):静止画面/新连入也能立刻看到,不必等用户去动一下。
        // 与 onSampleBuffer 同在捕获队列上串行调用,编码 PTS 仍单调(host 时钟)。
        capture.onIdleResend = { [weak self] pb, pts in
            guard let self, self.isPeerActive else { return }
            self.encoder.encode(pb, pts: pts, forceKeyframe: true)
        }
        // 捕获中途死掉(显示器深睡/登出/SCK 故障)→ 拆干净后按退避自动恢复,不能让被控端永久黑屏。
        capture.onError = { [weak self] error in
            NSLog("[直控] 捕获中断,将自动恢复: \(error)")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.capture.stop()
                self.scheduleCaptureRestart()
            }
        }

        // 音频侧:系统音频帧 → (AAC/PCM)AudioPacket → 经同一连接推给 Client(回调在捕获音频队列,线程安全)。
        // 一帧经 AAC 编码可能产出 0..N 个包(每包 1024 样本),逐个发送。无人观看时同样跳过。
        capture.onAudioSampleBuffer = { [weak self] sampleBuffer in
            guard let self, self.isPeerActive else { return }
            for packet in self.audioPacker.pack(sampleBuffer) { self.server.send(packet) }
        }

        // 发送侧:每帧推给 Client(无连接时 HostServer 内部丢弃)。不再本地解码预览。
        // 自适应码率开启时顺手计发帧数(供 handleFeedback 算本机发帧 fps)。
        encoder.onPacket = { [weak self] packet in
            guard let self else { return }
            self.server.send(packet)
            if self.adaptive != nil {
                self.frameCountLock.lock(); self.sentFrameCount += 1; self.frameCountLock.unlock()
            }
        }

        startCaptureWithRetry()
    }

    /// 停止(由顶层 AppDelegate 在退出时调用)。
    func stop() {
        captureGeneration += 1   // 使挂起的捕获重启/迟到的启动结果全部失效
        capture.stop()
        encoder.stop()
        server.stop()
        clipboardSync.stop()
        sleepInhibitor.end()
    }
    /// 被控端须常驻:顶层 AppDelegate 据此让"关窗不退出"。
    var staysResidentOnWindowClose: Bool { true }
    /// 点 Dock 图标(窗口被关掉后)重新唤出小窗口。
    func showWindow() { window.makeKeyAndOrderFront(nil) }

    /// 点「切换角色」:收起本窗口,请求顶层回到角色选择(AppDelegate 负责 stop 本端)。
    @objc private func switchRoleTapped() {
        window.orderOut(nil)
        onSwitchRole?()
    }

    /// 点远控码 → 复制到剪贴板,并短暂反馈。
    @objc private func copyCode() {
        guard relayConfig != nil, !currentRoom.isEmpty else { return }   // 局域网无码
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(currentRoom, forType: .string)
        copyHint.stringValue = "✓ 已复制到剪贴板"
        copyHint.textColor = .systemGreen
        copyHintReset?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.copyHint.stringValue = "点击远控码可复制"
            self?.copyHint.textColor = .tertiaryLabelColor
        }
        copyHintReset = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    // MARK: - 被控开关 / 状态

    @objc private func toggleServing(_ sender: NSButton) {
        serving = (sender.state == .on)
        applyServing()
    }

    /// 刷新远控码:生成新码并持久化、旧码立即失效(已连的控制端会断,需用新码重连)。
    @objc private func refreshCode() {
        guard relayConfig != nil else { return }   // 局域网无码
        currentRoom = RoomCode.generate()
        UserDefaults.standard.set(currentRoom, forKey: Self.savedRoomKey)   // 存下,重启沿用这个新码
        relayConfig = relayConfig?.with(room: currentRoom)
        codeLabel.stringValue = currentRoom
        clientConnected = false
        applyServing()   // 用新码重连中转
    }

    /// 按 `serving` 启停服务:开 → 连中转/起局域网监听;关 → 停服务(中转上无 Host 在场,连不上)。
    /// 启动前先 stop() 彻底清理旧连接/channel,避免快速切换开关时新旧状态并存(竞态)。
    private func applyServing() {
        server.stop()
        clientConnected = false
        if serving {
            if let relay = relayConfig { server.startRelay(relay) } else { server.start(secret: lanSecret) }
        }
        refreshStatus()
    }

    /// 收到 Client 反馈(收帧 fps)→ 比本机发帧 fps,投递率喂控制器 → 改码率。仅 adaptive 开启时。
    private func handleFeedback(clientFps: Double) {
        guard adaptive != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastFeedbackUptime
        lastFeedbackUptime = now
        frameCountLock.lock(); let sent = sentFrameCount; sentFrameCount = 0; frameCountLock.unlock()
        guard elapsed > 0.2 else { return }
        let hostFps = Double(sent) / elapsed
        guard hostFps > 1 else { return }   // 本机几乎没发(静止画面)→ 不调,避免误判拥塞
        let ratio = min(1.0, clientFps / hostFps)
        // 显式取出→mutate→写回:避免对可选 struct 用 ?. 调 mutating 方法时状态写不回的歧义。
        guard var controller = adaptive else { return }
        let newBitrate = controller.update(deliveryRatio: ratio)
        adaptive = controller
        encoder.updateBitRate(newBitrate)
    }

    private func refreshStatus() {
        // 同步「对端在场」镜像给捕获/编码线程(所有 serving/clientConnected 变化都经过这里)。
        setPeerActive(serving && clientConnected)
        if !serving {
            statusLabel.stringValue = "⊘ 已关闭"
            statusLabel.textColor = .secondaryLabelColor
        } else if clientConnected {
            statusLabel.stringValue = "● 控制端已连接"
            statusLabel.textColor = .systemGreen
        } else {
            statusLabel.stringValue = "○ 等待连接"
            statusLabel.textColor = .secondaryLabelColor
        }
    }
}
