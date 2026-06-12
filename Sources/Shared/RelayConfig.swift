import Foundation

/// 外网中转配置 —— **中转地址 + 端到端口令**。远控码(配对码)不在这里:它是**动态的**
/// (被控端生成/刷新、控制端输入),由两端 `with(room:)` 填入。
///
/// **无内置中转**:不配置任何东西时走局域网(Bonjour),开箱即用、不需要服务器。
/// 外网使用请指向你**自建**的中转(见 `server/zkrelay.py`),来源(优先级:env > `~/.zhikong/relay.conf`):
///   地址:`ZHIKONG_RELAY=ip:port` / relay.conf 第 1 字段(未配置 → 局域网)
///   口令:`ZHIKONG_SECRET` / relay.conf 第 2 字段(可选,**绝不发给中转**,两端一致)
///   固定码:`ZHIKONG_ROOM`(可选,测试用;默认空 → 动态生成/输入)
/// `ZHIKONG_LAN=1` → 强制走局域网 Bonjour。
///
/// 连上中转后先发握手 `ZKRELAY <HOST|CLIENT> <ROOM>\n`,之后即端到端加密字节流。中转只看到房间码,
/// 看不到口令、解不开内容。**口令(若设)不上链路 → 比"用房间码派生"更安全**。
struct RelayConfig {
    let host: String
    let port: UInt16
    /// 配对码(动态):被控端生成、控制端输入。`load()` 出来通常为空,两端 `with(room:)` 填。
    let room: String
    /// 端到端加密口令(可选,不发中转)。缺省则退回用房间码派生(`usesFallbackSecret`,弱,告警)。
    let secret: String?

    var effectiveSecret: String { secret ?? room }
    var usesFallbackSecret: Bool { secret == nil }

    /// 解析中转地址 + 口令(房间码动态,不在此)。
    /// 未显式配置中转地址(env `ZHIKONG_RELAY` 或 `~/.zhikong/relay.conf` 第 1 字段)→ nil → 走局域网 Bonjour。
    /// `ZHIKONG_LAN=1` 亦强制 nil。**不内置任何中转地址**:外网请指向自建中转。
    static func load() -> RelayConfig? {
        let env = ProcessInfo.processInfo.environment
        if env["ZHIKONG_LAN"] == "1" { return nil }

        guard let relay = clean(env["ZHIKONG_RELAY"]) ?? fileField(0),
              let (host, port) = parseAddr(relay) else { return nil }

        let secret = clean(env["ZHIKONG_SECRET"]) ?? clean(fileField(1))
        let room = clean(env["ZHIKONG_ROOM"]) ?? ""
        return RelayConfig(host: host, port: port, room: room, secret: secret)
    }

    /// 局域网模式的端到端口令(可选):`ZHIKONG_SECRET` / relay.conf 第 2 字段(地址字段可不存在)。
    /// 配了 → 局域网会话同样走 ChaCha20-Poly1305(两端一致);没配 → 保持零配置明文(向后兼容)。
    static func loadLANSecret() -> String? {
        let env = ProcessInfo.processInfo.environment
        return clean(env["ZHIKONG_SECRET"]) ?? clean(fileField(1))
    }

    /// relay.conf 首行有效配置的第 index 个字段(空格分隔;# 注释/空行跳过)。无则 nil。
    private static func fileField(_ index: Int) -> String? {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".zhikong/relay.conf")
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for raw in content.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(separator: " ").filter { !$0.isEmpty }
            return index < fields.count ? String(fields[index]) : nil
        }
        return nil
    }

    private static func parseAddr(_ s: String) -> (String, UInt16)? {
        let parts = s.split(separator: ":")
        guard parts.count == 2, !parts[0].isEmpty, let port = UInt16(parts[1]) else { return nil }
        return (String(parts[0]), port)
    }

    private static func clean(_ s: String?) -> String? {
        let t = s?.trimmingCharacters(in: .whitespaces)
        return (t?.isEmpty ?? true) ? nil : t
    }

    /// 换房间(远控码)生成新配置,地址与口令不变。被控端刷新码 / 控制端输码都用它。
    func with(room newRoom: String) -> RelayConfig {
        RelayConfig(host: host, port: port, room: newRoom, secret: secret)
    }

    /// 握手行字节(含结尾换行)。role 为 "HOST" 或 "CLIENT"。
    func handshake(role: String) -> Data {
        Data("ZKRELAY \(role) \(room)\n".utf8)
    }
}
