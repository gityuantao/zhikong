import CryptoKit
import Foundation

/// 端到端加密信道(仅外网/中转模式启用)。**中转服务器只转发密文,拿不到口令,无法解密屏幕/输入。**
///
/// ## 设计要点(刻意选最不易错的方案)
/// - 算法 **ChaCha20-Poly1305**(CryptoKit `ChaChaPoly`):AEAD,同时保机密性 + 完整性(防篡改/防注入)。
/// - **每帧独立随机 nonce**:`ChaChaPoly.seal` 不传 nonce 时自动生成 96-bit 随机 nonce,放进
///   `.combined`(`nonce‖ciphertext‖tag`)。于是 **无需握手协商、无需 nonce 计数器、重连天然无状态**——
///   这正是相比"固定密钥 + 计数器"最稳的点:计数器在重连时归零会造成 (key,nonce) 复用,对 AEAD 是
///   灾难性漏洞。随机 96-bit nonce 在同一密钥下 ~2^32 帧内碰撞概率可忽略(60fps 连续跑两年量级),
///   家用远控绰绰有余。
/// - 密钥由共享口令 **HKDF-SHA256** 派生(固定 salt/info,两端确定一致)。
/// - **方向绑进 AAD**:Host 发的帧用 "H2C" 认证,Client 发的帧用 "C2H";收方用"期望的对端方向"开箱。
///   中转若把某向帧回灌另一向(反射),会因 AAD 不符开箱失败 → 丢弃,不会被误当成有效帧。
/// - 4 字节长度前缀仍在信道**外**保持明文(由 `StreamFramer` 加):中转据此切帧/丢帧的逻辑一行不改;
///   被加密的只是前缀后的整条载荷(`VideoFramePacket`/`AudioPacket`/`InputEvent`)。每帧独立加密、
///   无链式依赖,故中转丢帧、Client 中途加入都能逐帧独立解密。
///
/// ## 密钥来源(为何不能用房间码)
/// 口令**绝不发给中转**;发给中转的是房间码(用于配对)。若用房间码当密钥,则链路窃听者从明文握手
/// `ZKRELAY HOST <room>` 就能拿到房间码 → 推出密钥 → 解密,等于没加密。故必须用一个**不上链路**的
/// 独立口令(两端各自本地配置一致)。未配独立口令时退化为房间码派生(`RelayConfig.usesFallbackSecret`),
/// 仅用于不破坏既有可用性,会在启动时告警。
///
/// **线程安全**:`final class` + 全 `let` 不可变。它由一个线程(主线程 startRelay)赋值给
/// `channel` 属性、另一个线程(NWConnection 内部队列的收发回调)读取并调 seal/open。引用类型 +
/// 内容不可变 ⇒ 跨线程共享同一实例安全,且属性的赋值/读取是单字长指针存取(struct 会被撕裂)。
final class SecureChannel {
    enum Direction { case hostToClient, clientToHost }

    private let key: SymmetricKey
    private let sealAAD: Data   // 本端发送方向标签
    private let openAAD: Data   // 期望收到的对端方向标签

    init(secret: String, sending: Direction) {
        let ikm = SymmetricKey(data: Data(secret.utf8))
        self.key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: Data("zhikong-e2e-v1".utf8),
            info: Data("zhikong-stream".utf8),
            outputByteCount: 32)
        let h2c = Data("H2C".utf8), c2h = Data("C2H".utf8)
        switch sending {
        case .hostToClient: (sealAAD, openAAD) = (h2c, c2h)
        case .clientToHost: (sealAAD, openAAD) = (c2h, h2c)
        }
    }

    /// 明文 → combined 密文(`nonce‖ciphertext‖tag`)。失败返回 nil(调用方应丢该帧,**绝不退回明文**)。
    func seal(_ plaintext: Data) -> Data? {
        guard let box = try? ChaChaPoly.seal(plaintext, using: key, authenticating: sealAAD) else { return nil }
        return box.combined
    }

    /// combined 密文 → 明文。任何失败(口令不一致 / 被篡改 / 截断 / 方向不符)返回 nil(丢帧,不崩)。
    func open(_ ciphertext: Data) -> Data? {
        guard let box = try? ChaChaPoly.SealedBox(combined: ciphertext) else { return nil }
        return try? ChaChaPoly.open(box, using: key, authenticating: openAAD)
    }
}
