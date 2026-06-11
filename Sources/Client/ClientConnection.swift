import Network
import Foundation

/// Client 端:用 `NWBrowser` 在 Bonjour 上发现 `_zhikong._tcp` 服务,
/// `NWConnection` 连上后持续接收字节流,经 `StreamFramer` 解帧,再用
/// `VideoFramePacket.decode` 还原每帧,通过 `onPacket` 上抛。
///
/// M3 单 Host 场景:发现多个结果时取第一个。
final class ClientConnection {
    /// 成功解出一帧视频时回调(在内部串行队列上)。
    var onPacket: ((VideoFramePacket) -> Void)?
    /// 成功解出一帧音频时回调(在内部串行队列上)。
    var onAudioPacket: ((AudioPacket) -> Void)?
    /// 收到 Host 发来的剪贴板文本时回调(在内部串行队列上)。
    var onClipboard: ((String) -> Void)?
    /// 中转告知对端(被控端)是否在线(在内部串行队列上)。仅外网中转模式有。
    var onPeerPresence: ((Bool) -> Void)?
    /// 连接状态文案变化时回调(在内部串行队列上),供 UI 显示。
    var onStateChange: ((String) -> Void)?
    /// 连接断开/失败时回调(内部串行队列)。供上层清理(如清空音频播放队列)。
    var onDisconnect: (() -> Void)?

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var framer = StreamFramer()
    private let queue = DispatchQueue(label: "com.zhikong.client.conn")
    private var relayConfig: RelayConfig?
    /// 端到端加密信道(仅外网/中转模式启用;局域网为 nil 走明文)。Client 发 C2H、收 H2C。
    /// 无状态(每帧随机 nonce),重连无需重置;`stop()` 时清空。
    ///
    /// **跨线程**:写在内部队列(startRelay/reconnect/stop)、读在内部队列(receive)与主线程(send,
    /// 由 controlView.onInput 调)。用锁保护;getter 持锁期间已对返回值 retain,另一线程置 nil/释放也不 UAF。
    private let channelLock = NSLock()
    private var _channel: SecureChannel?
    private var channel: SecureChannel? {
        get { channelLock.lock(); defer { channelLock.unlock() }; return _channel }
        set { channelLock.lock(); _channel = newValue; channelLock.unlock() }
    }

    /// 启动发现。发现首个服务即连接。
    func start() {
        let browser = NWBrowser(for: .bonjour(type: "_zhikong._tcp", domain: nil), using: .init())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.connection == nil, let first = results.first else { return }
            self.connect(to: first.endpoint)
        }
        browser.start(queue: queue)
        self.browser = browser
        onStateChange?("正在搜索被控 Mac…")
    }

    /// 外网模式:出站连中转(替代 Bonjour 发现)。复用同一 receive()/send()/route()。
    /// 连上后先发握手声明 CLIENT+房间,中转据此与 Host 配对。
    func startRelay(_ config: RelayConfig) {
        relayConfig = config
        // 外网链路端到端加密:Client 发输入(C2H)、收视频/音频(H2C)。
        channel = SecureChannel(secret: config.effectiveSecret, sending: .clientToHost)
        onStateChange?("正在连接中转…")
        connectToRelay()
    }

    /// 换远控码(房间)重连:断开当前连接,用新房间重新连中转。在内部队列上执行以避免与回调竞争。
    /// 旧连接的 .cancelled 处理因「conn !== self.connection」而跳过(见 connectToRelay 的身份判定),
    /// 不会触发对旧房间的重连。
    func reconnect(to config: RelayConfig) {
        queue.async { [weak self] in
            guard let self else { return }
            self.relayConfig = config
            self.channel = SecureChannel(secret: config.effectiveSecret, sending: .clientToHost)
            let old = self.connection
            self.connection = nil       // 先置空 → 旧连接回调失配跳过
            old?.cancel()
            self.onStateChange?("正在连接中转(房间 \(config.room))…")
            self.connectToRelay()
        }
    }

    private func connectToRelay() {
        guard let config = relayConfig, let port = NWEndpoint.Port(rawValue: config.port) else { return }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let conn = NWConnection(host: NWEndpoint.Host(config.host), port: port,
                                using: NWParameters(tls: nil, tcp: tcp))
        self.framer = StreamFramer()
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                conn.send(content: config.handshake(role: "CLIENT"), completion: .contentProcessed { _ in })
                self.onStateChange?("已连中转(房间 \(config.room))")
                self.receive()
            case .failed, .cancelled:
                // 仅当回调对应的仍是当前连接才处理(换房间重连时旧连接的 cancel 会走到这里,须跳过)。
                guard conn === self.connection else { return }
                self.onStateChange?("中转断开,重连中…")
                self.onDisconnect?()
                self.connection = nil
                // 外网易断:2 秒后重连(仅当未 stop / 未被新连接取代)。
                self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, self.relayConfig != nil, self.connection == nil else { return }
                    self.connectToRelay()
                }
            default:
                break
            }
        }
        self.connection = conn
        conn.start(queue: queue)
    }

    private func connect(to endpoint: NWEndpoint) {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true   // 关闭 Nagle:输入事件与接收都即时,减少顿挫
        let conn = NWConnection(to: endpoint, using: NWParameters(tls: nil, tcp: tcpOptions))
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onStateChange?("已连接")
                self.receive()
            case .failed, .cancelled:
                self.onStateChange?("连接断开")
                self.onDisconnect?()
                self.connection = nil
            default:
                break
            }
        }
        conn.start(queue: queue)
        connection = conn
    }

    private func receive() {
        let conn = connection
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            // 仅当回调对应的仍是当前连接才处理(换房间/重连时旧连接的 in-flight 回调会迟到,
            // 若不拦,会把旧字节灌进已为新连接重置的 framer → 解帧错位/串包)。镜像 HostServer.receiveInput。
            guard conn === self.connection else { return }
            if let data, !data.isEmpty {
                for payload in self.framer.append(data) {
                    // 中转控制帧(明文 5 字节 ZKRL)→ 在开箱前拣出,报对端在线状态。
                    if payload.count == RelayControl.frameLength, let present = RelayControl.decodePresence(payload) {
                        self.onPeerPresence?(present)
                        continue
                    }
                    // 外网模式先开箱(失败=口令不一致/篡改/方向不符 → 丢弃);局域网直接路由明文。
                    if let channel = self.channel {
                        guard let plain = channel.open(payload) else { continue }
                        self.route(plain)
                    } else {
                        self.route(payload)
                    }
                }
            }
            if error == nil && !isComplete {
                self.receive() // 继续递归收下一块。
            } else {
                self.onStateChange?("连接断开")
                self.onDisconnect?()
                self.connection = nil
            }
        }
    }

    /// 按 4 字节 magic 把一条载荷分流到视频/音频解码(ZKV1=视频,ZKA1=音频)。
    private func route(_ payload: Data) {
        guard payload.count >= 4 else { return }
        let magic = Array(payload.prefix(4))
        if magic == VideoFramePacket.magic {
            if let packet = VideoFramePacket.decode(payload) { onPacket?(packet) }
        } else if magic == AudioPacket.magic {
            if let packet = AudioPacket.decode(payload) { onAudioPacket?(packet) }
        } else if magic == ClipboardMessage.magic {
            if let text = ClipboardMessage.decode(payload) { onClipboard?(text) }
        }
    }

    /// 反向通道:把一条输入事件经同一连接发回 Host(长度前缀分帧)。
    /// 仅在连接就绪时发送,否则静默丢弃(输入不重传)。
    func send(_ event: InputEvent) {
        sendFramed(event.encode())
    }

    /// 发送剪贴板文本(magic ZKC1)给 Host。与输入事件复用同一加密/分帧。
    func sendClipboard(_ text: String) {
        sendFramed(ClipboardMessage.encode(text))
    }

    /// 发送链路反馈(近 1s 收帧 fps,magic ZKFB)给 Host,供其自适应码率。
    func sendFeedback(fps: Double) {
        sendFramed(FeedbackMessage.encode(fps: fps))
    }

    /// 统一发送口:外网模式先端到端加密载荷,再长度前缀分帧;加密失败丢弃(绝不退明文)。
    private func sendFramed(_ payload: Data) {
        guard let connection, case .ready = connection.state else { return }
        let body: Data
        if let channel {
            guard let sealed = channel.seal(payload) else { return }
            body = sealed
        } else {
            body = payload
        }
        connection.send(content: StreamFramer.frame(body), completion: .contentProcessed { _ in })
    }

    func stop() {
        relayConfig = nil   // 停止外网重连循环
        channel = nil
        connection?.cancel()
        browser?.cancel()
        connection = nil
        browser = nil
    }
}
