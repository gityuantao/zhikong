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
    private var backButton: NSTextField!
    /// 顶层 AppDelegate 注入:点「切换角色」时停掉本端、回到角色选择窗。
    var onSwitchRole: (() -> Void)?
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
    /// 局域网模式的端到端口令(可选)。配了 → LAN 会话也加密(两端须一致)。
    private var lanSecret: String?
    /// 本次连接尝试中,传输层是否就绪过(TCP 连上了被控端/中转)。
    /// 用于把超时失败分成两类:根本连不上 vs 连上了但收不到画面(口令不符/权限)。
    private var sawTransportReady = false
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

    /// 连接阶段状态机:点「连接」→ `connecting`(留在小窗等待),拿到正向信号(被控端在线 / 收到首帧)
    /// 才打开大会话窗;超时/失败 → 留在小窗直接报错,**绝不打开黑屏大窗**。
    private var connecting = false
    private var connectTimeoutTimer: Timer?
    /// 本次连接是否收到过中转在线帧(用来区分失败原因:"被控端不在线" vs "连不上中转")。
    private var sawPeerPresence = false
    private static let connectTimeout: TimeInterval = 8
    /// 会话中被控端掉线的宽限:超过它仍未恢复 → 判定被控端已退出,自动回连接窗(不卡在冻结画面)。
    private var peerLostTimer: Timer?
    private static let peerLostGrace: TimeInterval = 1.5

    /// 启动控制端(由顶层 AppDelegate 在选角色后调用)。
    func start() {
        buildConnectWindow()
        buildSessionWindow()

        // 手势诊断模式:只跑被动探针,不连、不弹会话窗口。
        if ProcessInfo.processInfo.environment["ZHIKONG_GESTURE_PROBE"] == "1" {
            _ = keyCapture.ensureAccessibility()
            setConnectStatus("🔬 手势诊断模式 — 按终端提示做动作,日志发回")
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
        connectWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 130),
                                 styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        connectWindow.title = "直控 — 连接"
        connectWindow.isReleasedWhenClosed = false
        guard let content = connectWindow.contentView else { return }

        // ‹ 切换角色(左上角,左缘与输入框对齐)
        backButton = makeLinkLabel("‹ 切换角色", target: self, action: #selector(switchRoleTapped))
        content.addSubview(backButton)

        // 一行:远控码输入框(左)+「连接」按钮(右)
        codeField = NSTextField(string: "")
        codeField.placeholderString = "远控码"
        codeField.font = .monospacedSystemFont(ofSize: 16, weight: .bold)
        codeField.alignment = .center
        codeField.delegate = self   // 回车连接靠 delegate(只在真按回车时触发,不会启动时自动连)
        content.addSubview(codeField)

        connectButton = NSButton(title: "连接", target: self, action: #selector(connectTapped))
        connectButton.bezelStyle = .rounded
        content.addSubview(connectButton)

        // 输入说明(放在输入框下方)
        captionLabel = NSTextField(labelWithString: "输入被控端的远控码")
        captionLabel.font = .systemFont(ofSize: 11)
        captionLabel.textColor = .secondaryLabelColor
        captionLabel.alignment = .left
        content.addSubview(captionLabel)

        // 状态/提示:多行自动换行,**仅在有内容时撑高窗口**(无内容时窗口保持紧凑)。
        connectStatus = NSTextField(wrappingLabelWithString: "")
        connectStatus.font = .systemFont(ofSize: 11)
        connectStatus.textColor = .secondaryLabelColor
        connectStatus.alignment = .left
        connectStatus.isEditable = false
        connectStatus.isSelectable = false
        connectStatus.maximumNumberOfLines = 0
        connectStatus.lineBreakMode = .byWordWrapping
        content.addSubview(connectStatus)

        relayoutConnect(statusHeight: 0)   // 初始紧凑布局
    }

    /// 紧凑布局:无提示时窗口最小;有提示(statusHeight>0)按需撑高。重排时保持窗口**顶边不动**(向下生长)。
    private func relayoutConnect(statusHeight: CGFloat) {
        let w: CGFloat = 360, padX: CGFloat = 20, btnW: CGFloat = 76
        let backH: CGFloat = 18, rowH: CGFloat = 28, capH: CGFloat = 14
        let topPad: CGFloat = 12, gapBackRow: CGFloat = 12, gapRowCap: CGFloat = 6
        let gapCapStatus: CGFloat = statusHeight > 0 ? 9 : 0
        let bottomPad: CGFloat = 16
        let contentH = topPad + backH + gapBackRow + rowH + gapRowCap + capH + gapCapStatus + statusHeight + bottomPad

        let topY = connectWindow.frame.maxY                 // 保持顶边不动
        connectWindow.setContentSize(NSSize(width: w, height: contentH))
        connectWindow.setFrameOrigin(NSPoint(x: connectWindow.frame.origin.x, y: topY - connectWindow.frame.height))

        let backY = contentH - topPad - backH
        backButton.frame = NSRect(x: padX, y: backY, width: 110, height: backH)   // 左缘与输入框精确对齐(label 无内边距)
        let rowY = backY - gapBackRow - rowH
        let fieldW = w - padX - btnW - 8 - padX
        codeField.frame = NSRect(x: padX, y: rowY, width: fieldW, height: rowH)
        connectButton.frame = NSRect(x: w - padX - btnW, y: rowY, width: btnW, height: rowH)
        let capY = rowY - gapRowCap - capH
        captionLabel.frame = NSRect(x: padX, y: capY, width: fieldW, height: capH)
        connectStatus.frame = NSRect(x: padX, y: capY - gapCapStatus - statusHeight, width: w - padX - padX, height: statusHeight)
    }

    /// 设状态文案并按内容高度撑高/收起窗口(空串=收起到紧凑)。所有状态展示统一走这里。
    private func setConnectStatus(_ text: String, color: NSColor = .secondaryLabelColor) {
        connectStatus.stringValue = text
        connectStatus.textColor = color
        var h: CGFloat = 0
        if !text.isEmpty {
            let rect = (text as NSString).boundingRect(
                with: NSSize(width: CGFloat(320), height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: NSFont.systemFont(ofSize: 11)])
            h = ceil(rect.height) + 2
        }
        relayoutConnect(statusHeight: h)
    }

    /// 点「切换角色」:收起本端窗口,请求顶层回到角色选择(AppDelegate 负责 stop 本端)。
    @objc private func switchRoleTapped() {
        connectWindow.orderOut(nil)
        sessionWindow.orderOut(nil)
        onSwitchRole?()
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
        if connecting { cancelConnecting(); return }   // 连接中再点同一按钮 = 取消
        guard !sessionWindow.isVisible else { return }   // 已在会话不处理
        if let base = relayConfigBase {   // 外网
            let code = RoomCode.normalize(codeField.stringValue)   // 去空格 + 转大写,避免大小写不匹配
            guard !code.isEmpty else { showConnectError("请输入远控码"); return }
            codeField.stringValue = code
            UserDefaults.standard.set(code, forKey: "zhikong.lastRoom")   // 记住,下次预填
            beginConnecting()
            conn.reconnect(to: base.with(room: code))   // 首次连接/换房间统一走 reconnect
            startFeedbackTimer()
        } else {                          // 局域网
            beginConnecting()
            conn.start(secret: lanSecret)
        }
        // 注意:此处**不再**直接 openSession()。会话窗只在拿到正向信号(被控端在线 / 收到首帧)后才开,
        // 见 onPeerPresence / onPacket → openSession();失败则 connectTimedOut() 留在小窗报错。
    }

    /// 进入"连接中"状态:禁用按钮、起超时计时,清空上次画面状态。
    private func beginConnecting() {
        connecting = true
        firstFrameReceived = false
        peerOnline = false
        sawPeerPresence = false
        sawTransportReady = false
        controlView.clear()
        connectButton.isEnabled = true       // 连接中保持可点 → 充当「取消」
        connectButton.title = "取消"
        setConnectStatus(relayConfigBase != nil ? "正在连接…" : "正在搜索局域网被控 Mac…")
        connectTimeoutTimer?.invalidate()
        connectTimeoutTimer = Timer.scheduledTimer(withTimeInterval: ClientController.connectTimeout, repeats: false) { [weak self] _ in
            self?.connectTimedOut()
        }
    }

    /// 超时仍未拿到正向信号 → 按"为什么没连上"给定向失败提示,留在小窗。
    private func connectTimedOut() {
        guard connecting else { return }
        let reason: String
        if relayConfigBase == nil {
            reason = sawTransportReady
                ? "已连上被控端但收不到画面。请检查:两端口令是否一致(ZHIKONG_SECRET / relay.conf)、被控端是否已授权『屏幕录制』。"
                : "未发现局域网被控端。请确认对方已打开「直控」选『被控端』，且在同一网络。"
        } else if sawPeerPresence {
            reason = "被控端不在线。请确认对方已打开「直控」、勾选『允许远程控制』，且远控码一致。"
        } else {
            reason = "连不上中转。请检查网络，或中转地址配置(~/.zhikong/relay.conf)。"
        }
        failConnect(reason)
    }

    /// 连接中点「取消」:停止本次连接尝试,回到空闲(可重新输码再连)。
    private func cancelConnecting() {
        conn.stop()
        feedbackTimer?.invalidate(); feedbackTimer = nil
        endConnecting()
        setConnectStatus("已取消")
    }

    /// 连接失败:停连接、复位按钮、红字报错(留在小窗,不开会话窗)。
    private func failConnect(_ reason: String) {
        conn.stop()
        feedbackTimer?.invalidate(); feedbackTimer = nil
        endConnecting()
        showConnectError(reason)
    }

    private func showConnectError(_ text: String) {
        setConnectStatus(text, color: .systemRed)
    }

    /// 退出"连接中"状态(成功开会话或失败都调):复位按钮、停超时计时。
    private func endConnecting() {
        connecting = false
        connectTimeoutTimer?.invalidate(); connectTimeoutTimer = nil
        connectButton.isEnabled = true
        connectButton.title = "连接"
    }

    /// 在远控码输入框里按回车 = 点连接。只在真实回车键时触发,故不会启动自动连(不像默认按钮 keyEquivalent)。
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            connectTapped()
            return true
        }
        return false
    }

    /// 打开大会话窗——**仅在连接中拿到正向信号时触发一次**(被控端在线 / 收到首帧)。
    /// `endConnecting()` 后 `connecting=false`,二次触发即 no-op(幂等)。
    private func openSession() {
        guard connecting else { return }
        endConnecting()
        connectWindow.orderOut(nil)
        sessionWindow.center()
        sessionWindow.makeKeyAndOrderFront(nil)
        sessionWindow.makeFirstResponder(controlView)
        NSApp.activate(ignoringOtherApps: true)
        updateSessionOverlay()                       // 据已知状态显示"接收画面…"/已出画面则隐藏
        if !firstFrameReceived { startNoVideoTimer() }
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

    /// 会话窗口被用户关闭 → 断开,回到连接窗口(不退出 app)。
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === sessionWindow else { return }
        // 用退出会话前的状态给连接窗口一个有意义的提示(被控端是否在线),而非笼统的"已断开"。
        let lastStatus = firstFrameReceived ? "" : (peerOnline ? "被控端在线但未收到画面(检查屏幕录制/口令)" : "被控端不在线")
        teardownSession()
        setConnectStatus(lastStatus)
        connectWindow.makeKeyAndOrderFront(nil)
        connectWindow.makeFirstResponder(codeField)
    }

    /// 被控端掉线(被动退出):停连接、回连接窗、给出原因——而非卡在冻结画面。
    /// 由 peerLostTimer(外网 presence=false 宽限后)/ 局域网直连断开 触发。
    private func leaveSession(reason: String) {
        teardownSession()
        sessionWindow.orderOut(nil)
        setConnectStatus(reason, color: .systemOrange)
        connectWindow.makeKeyAndOrderFront(nil)
        connectWindow.makeFirstResponder(codeField)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 统一清理会话相关连接/计时/播放与状态(回到干净的"未连接")。
    private func teardownSession() {
        conn.stop()
        feedbackTimer?.invalidate(); feedbackTimer = nil
        noVideoTimer?.invalidate(); noVideoTimer = nil
        peerLostTimer?.invalidate(); peerLostTimer = nil
        endConnecting()
        audioPlayer.reset()
        controlView.clear()
        firstFrameReceived = false
        peerOnline = false
    }

    /// 会话中被控端 presence 掉为离线 → 起宽限计时;期内未恢复(对方真退出/刷新码)即回连接窗。
    private func startPeerLostTimer() {
        peerLostTimer?.invalidate()
        peerLostTimer = Timer.scheduledTimer(withTimeInterval: ClientController.peerLostGrace, repeats: false) { [weak self] _ in
            guard let self, !self.peerOnline, self.sessionWindow.isVisible else { return }
            self.leaveSession(reason: "被控端已离线（已退出或刷新了远控码），请重新连接")
        }
    }

    // MARK: - 连接回调 / 捕获

    private func setupConnectionCallbacks() {
        conn.onStateChange = { [weak self] text in
            DispatchQueue.main.async { self?.setConnectStatus(text) }
        }
        // 传输层就绪(TCP 连上被控端/中转)——记下,供超时报错区分"连不上"与"连上但收不到画面"。
        conn.onReady = { [weak self] in
            DispatchQueue.main.async { self?.sawTransportReady = true }
        }
        // 中转报来被控端在线状态。驱动三件事:
        //  ① 连接中 + 在线 → 打开会话窗(正向信号);② 连接中 + 不在线 → 留在小窗等待;
        //  ③ 会话中 + 掉线 → 起宽限,超时回连接窗(被控端退出);④ 会话中 + 恢复在线 → 取消宽限、续播。
        conn.onPeerPresence = { [weak self] present in
            DispatchQueue.main.async {
                guard let self else { return }
                self.sawPeerPresence = true
                self.peerOnline = present
                if present {
                    self.peerLostTimer?.invalidate(); self.peerLostTimer = nil
                    if self.connecting { self.openSession(); return }
                    self.updateSessionOverlay()
                } else {
                    if self.connecting {
                        self.setConnectStatus("被控端暂未在线,等待对方开启…")
                    } else if self.sessionWindow.isVisible {
                        self.firstFrameReceived = false
                        self.controlView.clear()           // 不残留冻结画面
                        self.sessionStatus.isHidden = false
                        self.sessionStatus.stringValue = "被控端已断开…"
                        self.startPeerLostTimer()
                    }
                }
            }
        }
        conn.onAudioPacket = { [weak self] packet in self?.audioPlayer.play(packet) }
        conn.onDisconnect = { [weak self] in
            guard let self else { return }
            self.audioPlayer.reset()
            DispatchQueue.main.async {
                self.firstFrameReceived = false
                self.controlView.clear()
                if self.relayConfigBase == nil {
                    // 局域网:直连断开 = 被控端没了(无中转可重连)。
                    self.peerOnline = false
                    if self.sessionWindow.isVisible { self.leaveSession(reason: "被控端已断开") }
                    // 局域网连接中找不到被控端不会触发本回调,由 connectTimedOut 兜底。
                } else {
                    // 外网:我与中转的链路断了 → 中转 2s 自动重连;**不动 peerOnline**——
                    // 被控端在不在只由 presence 帧判定(链路断≠对端退出),重连后会重发 presence 校正。
                    if self.sessionWindow.isVisible {
                        self.sessionStatus.isHidden = false
                        self.sessionStatus.stringValue = "连接中断,重连中…"
                        self.startNoVideoTimer()
                    }
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
                // 解不出画面(中途加入还没等到关键帧 / 丢包失序)→ 主动要一个关键帧(已限频 0.5s),
                // 画面恢复从"等关键帧间隔"变"下一帧"。
                self.conn.requestKeyframe()
                NSLog("[直控-Client] 重建 CMSampleBuffer 失败(pts=\(packet.pts), key=\(packet.isKeyframe)),已请求关键帧")
                return
            }
            DispatchQueue.main.async {
                self.onFirstVideoFrame()        // 标记已出画面 + 隐藏浮层
                self.openSession()              // 幂等:连接中收到首帧 = 正向信号 → 开窗;已在会话则 no-op
                self.controlView.enqueue(sample)
            }
        }
    }

    private func setupCaptures() {
        // 剪贴板双向同步。
        clipboardSync.onLocalChange = { [weak self] text in self?.conn.sendClipboard(text) }
        clipboardSync.start()

        // 系统键盘 / 手势捕获(仅会话窗口聚焦时消费转发)。
        accessibilityTrusted = keyCapture.ensureAccessibility()
        if !accessibilityTrusted {
            setConnectStatus("提示:键盘快捷键透传需在 系统设置›隐私›辅助功能 授权后重启")
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
            lanSecret = RelayConfig.loadLANSecret()
            captionLabel.stringValue = lanSecret != nil ? "局域网模式(加密) · 无需远控码" : "局域网模式 · 无需远控码"
            codeField.stringValue = ""
            codeField.placeholderString = "—"
            codeField.isEnabled = false
            setConnectStatus("点「连接」自动发现同网被控 Mac")
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
        connectTimeoutTimer?.invalidate()
        peerLostTimer?.invalidate()
        conn.stop()
    }
    /// 控制端非常驻:关连接窗口=退出 app(关会话窗口只是回连接窗口,见 windowWillClose)。
    var staysResidentOnWindowClose: Bool { false }
}
