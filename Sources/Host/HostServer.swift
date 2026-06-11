import Network
import Foundation

/// Host 端局域网服务:用 `NWListener` 在 Bonjour 上广播 `_zhikong._tcp`,
/// 接受 Client 的 TCP 连接,并把每个 `VideoFramePacket` 以长度前缀分帧后发送。
///
/// M3 单 Host 单 Client:新连接到来时取代旧连接(`connection?.cancel()`)。
final class HostServer {
    /// Client 连接就绪(可发送)时回调。在内部串行队列上触发。
    var onClientConnected: (() -> Void)?
    /// Client 连接断开/失败时回调。
    var onClientDisconnected: (() -> Void)?
    /// 收到 Client 发来的输入事件时回调(在内部串行队列上)。
    var onInputEvent: ((InputEvent) -> Void)?
    /// 收到 Client 发来的剪贴板文本时回调(在内部串行队列上)。
    var onClipboard: ((String) -> Void)?
    /// 收到 Client 链路反馈(近 1s 收帧 fps)时回调(在内部串行队列上),供自适应码率。
    var onFeedback: ((Double) -> Void)?
    /// 中转告知对端(控制端)是否在线(在内部串行队列上)。仅外网中转模式有。
    var onPeerPresence: ((Bool) -> Void)?

    /// 以下可变状态(listener/framer/relayConfig)**只在内部串行队列上**读写:
    /// start/startRelay/stop 把自己的工作体 async 到 queue,与 NWConnection 回调天然互斥。
    private var listener: NWListener?
    /// 反向通道(Client→Host 输入流)的解帧器。每条新连接重置一个,
    /// 避免旧连接残留的半包污染新连接。
    private var framer = StreamFramer()
    private let queue = DispatchQueue(label: "com.zhikong.host.server")
    /// 端到端加密信道(仅外网/中转模式启用;局域网为 nil 走明文)。Host 发 H2C、收 C2H。
    /// 无状态(每帧随机 nonce),重连无需重置;`stop()` 时清空。
    ///
    /// **跨线程**:写在内部队列(startRelay/stop),读在多处不同线程(receiveInput 在内部队列、
    /// sendFramed 在编码/音频回调线程)。用锁保护读写,且 getter 在持锁期间已对返回值完成 ARC retain,
    /// 故即便另一线程同时置 nil/释放也不会 use-after-free。SecureChannel 内容不可变,持有副本调用安全。
    private let channelLock = NSLock()
    private var _channel: SecureChannel?
    private var channel: SecureChannel? {
        get { channelLock.lock(); defer { channelLock.unlock() }; return _channel }
        set { channelLock.lock(); _channel = newValue; channelLock.unlock() }
    }
    /// 当前连接。与 `channel` 同理加锁:写在内部队列,读还来自编码/音频回调线程(sendFramed)。
    /// 之前无保护的跨线程读写存在 ARC 竞态(读线程取引用恰逢写线程释放 → UAF),与 channel 同方案修复。
    private let connLock = NSLock()
    private var _connection: NWConnection?
    private var connection: NWConnection? {
        get { connLock.lock(); defer { connLock.unlock() }; return _connection }
        set { connLock.lock(); _connection = newValue; connLock.unlock() }
    }

    /// 启动监听并开始 Bonjour 广播。线程安全:工作体在内部队列执行。
    func start(serviceName: String = "ZhiKong-Studio") {
        queue.async { [weak self] in
            guard let self else { return }
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.noDelay = true   // 关闭 Nagle:小包立即发,避免实时视频流"攒包→突发"的顿挫
            let params = NWParameters(tls: nil, tcp: tcpOptions)
            guard let listener = try? NWListener(using: params) else {
                NSLog("[直控] HostServer 启动失败:无法创建 NWListener")
                return
            }
            listener.service = NWListener.Service(name: serviceName, type: "_zhikong._tcp")
            listener.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                // 单连接策略:新连接取代旧连接。重置反向通道解帧器(新连接的字节流从头算)。
                self.connection?.cancel()
                self.connection = conn
                self.framer = StreamFramer()
                conn.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    // 仅当回调对应的仍是当前连接才处理:被新连接顶替的旧连接,其迟到的
                    // .cancelled 不能把"新客户端已连接"误报成断开(.ready 同理防御)。
                    guard conn === self.connection else { return }
                    switch state {
                    case .ready:
                        self.onClientConnected?()
                        // 连接就绪后启动反向接收循环:收 Client 的输入事件。
                        self.receiveInput()
                    case .failed, .cancelled:
                        self.onClientDisconnected?()
                    default:
                        break
                    }
                }
                conn.start(queue: self.queue)
            }
            listener.start(queue: self.queue)
            self.listener = listener
        }
    }

    // MARK: - 外网模式(出站连中转,替代 NWListener+Bonjour)

    private var relayConfig: RelayConfig?

    /// 外网模式:出站连中转。复用同一 `connection` 的收发逻辑(send/receiveInput 不变)。
    /// 连上后先发握手声明 HOST+房间,中转据此与 Client 配对,之后字节流原样穿过。
    /// 线程安全:工作体在内部队列执行(与 stop/回调串行,启停顺序由队列保序)。
    func startRelay(_ config: RelayConfig) {
        queue.async { [weak self] in
            guard let self else { return }
            // 幂等:先断掉可能存在的旧连接,避免重复 startRelay 留下孤儿连接 + 新旧 channel 并存。
            self.connection?.cancel()
            self.relayConfig = config
            // 外网链路端到端加密:Host 发视频/音频(H2C)、收输入(C2H)。
            self.channel = SecureChannel(secret: config.effectiveSecret, sending: .hostToClient)
            self.connectToRelay()
        }
    }

    private func connectToRelay() {
        guard let config = relayConfig, let port = NWEndpoint.Port(rawValue: config.port) else { return }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let conn = NWConnection(host: NWEndpoint.Host(config.host), port: port,
                                using: NWParameters(tls: nil, tcp: tcp))
        self.connection = conn
        self.framer = StreamFramer()
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                conn.send(content: config.handshake(role: "HOST"), completion: .contentProcessed { _ in })
                NSLog("[直控] 已连中转 %@:%d room=%@", config.host, Int(config.port), config.room)
                self.onClientConnected?()
                self.receiveInput()
            case .failed, .cancelled:
                // 仅当仍是当前连接(未被 stop/新一轮 startRelay 顶替)才回调与重连。
                guard conn === self.connection else { return }
                self.connection = nil
                self.onClientDisconnected?()
                // 外网易断:2 秒后重连(仅当未 stop、且没有新连接顶上来)。
                self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, self.relayConfig != nil, self.connection == nil else { return }
                    self.connectToRelay()
                }
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    /// 发送一帧视频。仅在连接就绪时发送;否则丢弃(实时流不重传旧帧)。
    func send(_ packet: VideoFramePacket) {
        sendFramed(packet.encode())
    }

    /// 发送一帧音频。与视频复用同一连接、同一分帧;Client 按 magic(ZKA1/ZKV1)区分。
    func send(_ packet: AudioPacket) {
        sendFramed(packet.encode())
    }

    /// 发送剪贴板文本(magic ZKC1)。与音视频复用同一连接/加密/分帧。
    func sendClipboard(_ text: String) {
        sendFramed(ClipboardMessage.encode(text))
    }

    /// 统一发送口:外网模式先端到端加密载荷,再加长度前缀分帧;加密失败丢帧(**绝不退明文**)。
    /// 长度前缀始终明文,中转据此切帧/丢帧逻辑不变。
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

    /// 反向接收循环:从当前连接持续收字节,经 `framer` 解帧后 `InputEvent.decode`,
    /// 解出的事件经 `onInputEvent` 上抛(Host 侧再注入)。镜像 ClientConnection 的递归接收。
    /// 不影响视频发送——发送走 `send(_:)`,接收走这里,同一连接全双工。
    private func receiveInput() {
        let conn = connection
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            // 仅当回调对应的仍是当前连接时才处理(防止旧连接的回调污染新连接的 framer)。
            guard conn === self.connection else { return }
            if let data, !data.isEmpty {
                for payload in self.framer.append(data) {
                    // 中转控制帧(明文 5 字节 ZKRL)→ 在开箱前拣出,报对端在线状态。
                    if payload.count == RelayControl.frameLength, let present = RelayControl.decodePresence(payload) {
                        self.onPeerPresence?(present)
                        continue
                    }
                    // 外网模式先开箱(失败=口令不一致/篡改 → 丢弃);局域网直接用明文载荷。
                    let plain: Data
                    if let channel = self.channel {
                        guard let p = channel.open(payload) else { continue }
                        plain = p
                    } else {
                        plain = payload
                    }
                    // 反向通道可能携带:剪贴板(ZKC1)/ 链路反馈(ZKFB)/ 输入事件。按 magic 分流。
                    let head = Array(plain.prefix(4))
                    if head == ClipboardMessage.magic {
                        if let text = ClipboardMessage.decode(plain) { self.onClipboard?(text) }
                    } else if head == FeedbackMessage.magic {
                        if let fps = FeedbackMessage.decode(plain) { self.onFeedback?(fps) }
                    } else if let event = InputEvent.decode(plain) {
                        self.onInputEvent?(event)
                    }
                }
            }
            // 解帧器中毒(对端/中转宣告异常帧长,流已无法重对齐)→ 断开;重连会换新 framer。
            if self.framer.poisoned {
                NSLog("[直控] 反向流帧长异常,断开连接")
                conn?.cancel()
                return
            }
            if error == nil && !isComplete {
                self.receiveInput() // 继续递归收下一块。
            } else {
                // 出错或对端半关(EOF):统一 cancel,让 stateUpdateHandler(.cancelled)做
                // 断开回调与(外网)重连调度。若只停止递归,半关连接可能停留在 .ready,
                // 永远等不来 .failed → 外网模式不会自动重连。
                conn?.cancel()
            }
        }
    }

    /// 停止监听并断开连接。线程安全:工作体在内部队列执行。
    /// 刻意**强捕获 self**:上层 stop 后可能立刻释放本对象,弱捕获会跳过清理块 → 连接/监听泄漏。
    func stop() {
        queue.async {
            self.relayConfig = nil   // 停止外网重连循环
            self.channel = nil
            self.connection?.cancel()
            self.listener?.cancel()
            self.connection = nil
            self.listener = nil
        }
    }
}
