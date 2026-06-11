import AppKit
import CoreMedia

/// Client(控制端)委托。**两段式 UI**:
/// 1) 启动先弹**小连接窗口**——输入远控码、点「连接」;
/// 2) 连接后打开**大会话窗口**(远端画面,干净无叠层)。
/// 关闭会话窗口 = 断开、回到连接窗口。
/// 单 app 架构下由顶层 `AppDelegate`(角色选择)在选「控制端」后 `start()`;非 NSApplicationDelegate。
final class ClientController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    // 连接窗口(小)
    private var connectWindow: NSWindow!
    private var captionLabel: NSTextField!
    private var codeField: NSTextField!
    private var connectButton: NSButton!
    private var connectStatus: NSTextField!
    // 会话窗口(大)
    private var sessionWindow: NSWindow!
    private var controlView: RemoteControlView!
    /// 会话窗口里居中的状态浮层:连接中/等待画面/未收到画面(被控端没开等)。收到首帧即隐藏。
    private var sessionStatus: NSTextField!
    private var firstFrameReceived = false
    /// 中转报来的"被控端是否在线"(外网模式)。
    private var peerOnline = false
    /// 连上中转后,若 N 秒仍无画面 → 判定被控端可能不在线/没授权,给出排查提示。
    private var noVideoTimer: Timer?
    private static let noVideoTimeout: TimeInterval = 3.5

    /// 外网中转基配置(地址 + 口令);连接时以它为底 `with(room:)`。nil=局域网(无需码)。
    private var relayConfigBase: RelayConfig?
    private let conn = ClientConnection()
    private let builder = HEVCSampleBufferBuilder()
    private let audioPlayer = AudioPlayer()
    /// 系统键盘捕获 / 触控板手势捕获(CGEventTap,强引用:refcon 是 passUnretained(self),须比 tap 活得久)。
    private let keyCapture = SystemKeyCapture()
    private let gestureCapture = GestureCapture()
    private var accessibilityTrusted = true
    /// 剪贴板双向同步(纯文本)。
    private let clipboardSync = ClipboardSync()
    /// 链路反馈:统计近 1s 收到的视频帧数,定时上报给 Host(供其自适应码率)。
    private let recvFrameLock = NSLock()
    private var recvFrameCount = 0
    private var feedbackTimer: Timer?

    /// 启动控制端(由顶层 AppDelegate 在选角色后调用)。
    func start() {
        buildConnectWindow()
        buildSessionWindow()

        // 手势诊断模式:只跑被动探针,不连、不弹会话窗口。
        if ProcessInfo.processInfo.environment["ZHIKONG_GESTURE_PROBE"] == "1" {
            _ = keyCapture.ensureAccessibility()
            connectStatus.stringValue = "🔬 手势诊断模式 — 按终端提示做动作,日志发回"
            connectWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            GestureProbe.start()
            return
        }

        setupConnectionCallbacks()
        setupCaptures()
        loadConfigAndPrefill()

        connectWindow.center()
        connectWindow.makeKeyAndOrderFront(nil)
        connectWindow.makeFirstResponder(codeField)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 窗口构建

    private func buildConnectWindow() {
        let w: CGFloat = 380, h: CGFloat = 200
        connectWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                                 styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        connectWindow.title = "直控 — 连接"
        connectWindow.isReleasedWhenClosed = false

        captionLabel = NSTextField(labelWithString: "远控码")
        captionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        captionLabel.textColor = .secondaryLabelColor
        captionLabel.alignment = .center
        captionLabel.frame = NSRect(x: 0, y: h - 50, width: w, height: 16)
        connectWindow.contentView?.addSubview(captionLabel)

        codeField = NSTextField(string: "")
        codeField.placeholderString = "输入被控端显示的远控码"
        codeField.font = .monospacedSystemFont(ofSize: 18, weight: .bold)
        codeField.alignment = .center
        codeField.frame = NSRect(x: 40, y: h - 92, width: w - 80, height: 30)
        codeField.delegate = self   // 回车连接靠 delegate(只在真按回车时触发,不会启动时自动连)
        connectWindow.contentView?.addSubview(codeField)

        connectButton = NSButton(title: "连接", target: self, action: #selector(connectTapped))
        connectButton.bezelStyle = .rounded
        connectButton.frame = NSRect(x: (w - 120) / 2, y: 48, width: 120, height: 30)
        connectWindow.contentView?.addSubview(connectButton)

        connectStatus = NSTextField(labelWithString: "")
        connectStatus.font = .systemFont(ofSize: 11)
        connectStatus.textColor = .secondaryLabelColor
        connectStatus.alignment = .center
        connectStatus.lineBreakMode = .byTruncatingTail
        connectStatus.frame = NSRect(x: 10, y: 16, width: w - 20, height: 16)
        connectWindow.contentView?.addSubview(connectStatus)
    }

    private func buildSessionWindow() {
        sessionWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1146, height: 480),
                                 styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        sessionWindow.title = "直控"
        sessionWindow.isReleasedWhenClosed = false
        sessionWindow.delegate = self
        controlView = RemoteControlView(frame: sessionWindow.contentView!.bounds)
        controlView.autoresizingMask = [.width, .height]
        sessionWindow.contentView?.addSubview(controlView)
        controlView.onInput = { [weak self] event in self?.conn.send(event) }

        // 居中状态浮层:无画面时给提示(连接中/等待/被控端没开等),收到首帧即隐藏。
        let sw: CGFloat = 520, sh: CGFloat = 120
        sessionStatus = NSTextField(wrappingLabelWithString: "")
        sessionStatus.font = .systemFont(ofSize: 14, weight: .medium)
        sessionStatus.textColor = .white
        sessionStatus.backgroundColor = NSColor.black.withAlphaComponent(0.7)
        sessionStatus.drawsBackground = true
        sessionStatus.alignment = .center
        sessionStatus.isEditable = false
        sessionStatus.isSelectable = false
        let cb = sessionWindow.contentView!.bounds
        sessionStatus.frame = NSRect(x: (cb.width - sw) / 2, y: (cb.height - sh) / 2, width: sw, height: sh)
        sessionStatus.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        sessionWindow.contentView?.addSubview(sessionStatus)
    }

    // MARK: - 连接 / 会话切换

    @objc private func connectTapped() {
        if let base = relayConfigBase {   // 外网
            let code = RoomCode.normalize(codeField.stringValue)   // 去空格 + 转大写,避免大小写不匹配
            guard !code.isEmpty else { connectStatus.stringValue = "请输入远控码"; return }
            codeField.stringValue = code
            UserDefaults.standard.set(code, forKey: "zhikong.lastRoom")   // 记住,下次预填
            conn.reconnect(to: base.with(room: code))   // 首次连接/换房间统一走 reconnect
            startFeedbackTimer()
        } else {                          // 局域网
            conn.start()
        }
        openSession()
    }

    /// 在远控码输入框里按回车 = 点连接。只在真实回车键时触发,故不会启动自动连(不像默认按钮 keyEquivalent)。
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            connectTapped()
            return true
        }
        return false
    }

    private func openSession() {
        firstFrameReceived = false
        peerOnline = false
        controlView.clear()                 // 起始纯黑,不残留上次画面
        sessionStatus.isHidden = false
        sessionStatus.stringValue = "正在连接被控端…"   // 中转在线状态到达前的中性提示
        startNoVideoTimer()
        connectWindow.orderOut(nil)
        sessionWindow.center()
        sessionWindow.makeKeyAndOrderFront(nil)
        sessionWindow.makeFirstResponder(controlView)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 据"是否已出画面 / 被控端是否在线"刷新浮层。
    private func updateSessionOverlay() {
        guard sessionStatus != nil else { return }
        if firstFrameReceived { sessionStatus.isHidden = true; return }
        sessionStatus.isHidden = false
        if peerOnline {
            sessionStatus.stringValue = "被控端在线,正在接收画面…"
        } else {
            sessionStatus.stringValue = """
            被控端不在线。请在被控端那台 Mac:
            打开「直控」→ 选『被控端』→ 勾选『允许远程控制』
            (远控码:\(codeField.stringValue))
            """
        }
    }

    /// 连上后若 N 秒仍无画面:被控端"在线却收不到画面"= 多半权限/口令问题,给定向提示。
    private func startNoVideoTimer() {
        noVideoTimer?.invalidate()
        noVideoTimer = Timer.scheduledTimer(withTimeInterval: ClientController.noVideoTimeout, repeats: false) { [weak self] _ in
            guard let self, !self.firstFrameReceived, self.peerOnline else { return }
            self.sessionStatus.stringValue = """
            被控端在线,但收不到画面。请检查被控端:
            ① 已授权『屏幕录制』(系统设置›隐私与安全性,授权后需重启「直控」)
            ② 两端口令一致(若设过 ZHIKONG_SECRET)
            """
        }
    }

    /// 收到首帧 → 隐藏浮层(在主线程调)。
    private func onFirstVideoFrame() {
        guard !firstFrameReceived else { return }
        firstFrameReceived = true
        noVideoTimer?.invalidate(); noVideoTimer = nil
        sessionStatus.isHidden = true
    }

    /// 会话窗口被关闭 → 断开,回到连接窗口(不退出 app)。
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === sessionWindow else { return }
        // 用退出会话前的状态给连接窗口一个有意义的提示(被控端是否在线),而非笼统的"已断开"。
        let lastStatus = firstFrameReceived ? "" : (peerOnline ? "被控端在线但未收到画面(检查屏幕录制/口令)" : "被控端不在线")
        conn.stop()
        feedbackTimer?.invalidate(); feedbackTimer = nil
        noVideoTimer?.invalidate(); noVideoTimer = nil
        audioPlayer.reset()
        connectStatus.stringValue = lastStatus
        connectWindow.makeKeyAndOrderFront(nil)
        connectWindow.makeFirstResponder(codeField)
    }

    // MARK: - 连接回调 / 捕获

    private func setupConnectionCallbacks() {
        conn.onStateChange = { [weak self] text in
            DispatchQueue.main.async { self?.connectStatus.stringValue = text }
        }
        // 中转报来被控端在线状态 → 驱动会话浮层(即时、准确)。
        conn.onPeerPresence = { [weak self] present in
            DispatchQueue.main.async {
                guard let self else { return }
                self.peerOnline = present
                self.updateSessionOverlay()
            }
        }
        conn.onAudioPacket = { [weak self] packet in self?.audioPlayer.play(packet) }
        conn.onDisconnect = { [weak self] in
            guard let self else { return }
            self.audioPlayer.reset()
            DispatchQueue.main.async {
                // 中转连接断开 → 清画面、复位、重连中(被控端在线状态会在重连后重新到达)。
                self.firstFrameReceived = false
                self.peerOnline = false
                self.controlView.clear()
                if self.sessionWindow.isVisible {
                    self.sessionStatus.isHidden = false
                    self.sessionStatus.stringValue = "连接断开,重连中…"
                    self.startNoVideoTimer()
                }
            }
        }
        conn.onClipboard = { [weak self] text in
            DispatchQueue.main.async { self?.clipboardSync.applyRemote(text) }
        }
        conn.onPacket = { [weak self] packet in
            guard let self else { return }
            self.recvFrameLock.lock(); self.recvFrameCount += 1; self.recvFrameLock.unlock()
            guard let sample = self.builder.build(from: packet) else {
                NSLog("[直控-Client] 重建 CMSampleBuffer 失败(pts=\(packet.pts), key=\(packet.isKeyframe))")
                return
            }
            DispatchQueue.main.async { self.onFirstVideoFrame(); self.controlView.enqueue(sample) }
        }
    }

    private func setupCaptures() {
        // 剪贴板双向同步。
        clipboardSync.onLocalChange = { [weak self] text in self?.conn.sendClipboard(text) }
        clipboardSync.start()

        // 系统键盘 / 手势捕获(仅会话窗口聚焦时消费转发)。
        accessibilityTrusted = keyCapture.ensureAccessibility()
        if !accessibilityTrusted {
            connectStatus.stringValue = "提示:键盘快捷键透传需在 系统设置›隐私›辅助功能 授权后重启"
        }
        keyCapture.shouldCapture = { [weak self] in self?.isRemoteActive ?? false }
        keyCapture.onKey = { [weak self] event in self?.conn.send(event) }
        keyCapture.start()

        gestureCapture.shouldCapture = { [weak self] in self?.isRemoteActive ?? false }
        gestureCapture.onSwitchSpace = { [weak self] left in self?.conn.send(.switchSpace(left: left)) }
        gestureCapture.onVerticalGesture = { [weak self] up in self?.conn.send(.missionControl(up: up)) }
        gestureCapture.start()
    }

    private func loadConfigAndPrefill() {
        if let relay = RelayConfig.load() {
            NSLog("[直控] Client 外网模式 → 中转 %@:%d(端到端加密)", relay.host, Int(relay.port))
            if relay.usesFallbackSecret {
                NSLog("[直控] ⚠️ 未设独立端到端口令(relay.conf 第3字段 / ZHIKONG_SECRET),加密退化为房间码派生——防不住能看到握手的链路窃听者。建议两端配同一强口令。")
            }
            relayConfigBase = relay
            captionLabel.stringValue = "输入被控端的远控码"
            // 远控码是动态的(被控端窗口上显示):预填上次连过的;配置固定了码(ZHIKONG_ROOM)则用它。
            let lastUsed = UserDefaults.standard.string(forKey: "zhikong.lastRoom") ?? ""
            codeField.stringValue = relay.room.isEmpty ? lastUsed : relay.room
        } else {
            relayConfigBase = nil
            captionLabel.stringValue = "局域网模式"
            codeField.stringValue = ""
            codeField.placeholderString = "局域网自动发现,无需远控码"
            codeField.isEnabled = false
            connectStatus.stringValue = "点「连接」自动发现同网被控 Mac"
        }
    }

    // MARK: - 杂项

    private func startFeedbackTimer() {
        guard feedbackTimer == nil else { return }
        let t = Timer(timeInterval: 1.0, target: self, selector: #selector(sendFeedbackTick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        feedbackTimer = t
    }
    @objc private func sendFeedbackTick() {
        recvFrameLock.lock(); let n = recvFrameCount; recvFrameCount = 0; recvFrameLock.unlock()
        conn.sendFeedback(fps: Double(n))
    }

    /// 远程控制是否「激活」:app 在最前、**会话窗口**为 key、且画面视图是第一响应者。
    /// 最后一条很关键:在连接窗口输码时第一响应者是输入框,此时不消费键盘。
    private var isRemoteActive: Bool {
        guard NSApp.isActive, sessionWindow?.isKeyWindow ?? false else { return false }
        return sessionWindow?.firstResponder === controlView
    }

    /// 停止(由顶层 AppDelegate 在退出时调用)。
    func stop() {
        keyCapture.stop()
        gestureCapture.stop()
        audioPlayer.stop()
        clipboardSync.stop()
        feedbackTimer?.invalidate()
        conn.stop()
    }
    /// 控制端非常驻:关连接窗口=退出 app(关会话窗口只是回连接窗口,见 windowWillClose)。
    var staysResidentOnWindowClose: Bool { false }
}
