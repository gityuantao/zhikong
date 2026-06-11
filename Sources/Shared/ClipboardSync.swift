import AppKit

/// 剪贴板双向同步 —— 轮询本机 `NSPasteboard.general.changeCount`(系统无变更通知,只能轮询),
/// 本机剪贴板变化即经 `onLocalChange` 推给对端;收到对端内容用 `applyRemote` 写入本机。
///
/// **防回环**:写入收到的内容后,记下写入产生的 changeCount,轮询时跳过它(不再回推);
/// 且内容相同直接跳过。纯文本(覆盖绝大多数使用);图片/文件后续再说。
///
/// **线程**:全部在**主线程**(NSPasteboard 须主线程)。`applyRemote` 由网络回调调用方负责切主线程。
final class ClipboardSync {
    /// 本机剪贴板变化(用户在本机复制了东西)→ 把文本推给对端。
    var onLocalChange: ((String) -> Void)?

    private let pb = NSPasteboard.general
    private var lastChangeCount: Int
    /// 最近一次"同步过"的文本(发给对端 或 从对端写入的)。**基于内容防回环**——
    /// 比 changeCount 更稳:只要当前剪贴板内容等于上次同步的内容,就绝不再推送(杜绝 A→B→A 死循环)。
    private var lastSyncedText: String?
    private var timer: Timer?

    init() { lastChangeCount = pb.changeCount }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.5, target: self, selector: #selector(poll), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    @objc private func poll() {
        let cc = pb.changeCount
        guard cc != lastChangeCount else { return }
        lastChangeCount = cc
        guard let s = pb.string(forType: .string), !s.isEmpty else { return }
        if s == lastSyncedText { return }   // 内容与上次同步的相同 → 是回环或重复,不推
        lastSyncedText = s
        onLocalChange?(s)
    }

    /// 收到对端剪贴板文本 → 写入本机(主线程调用)。内容已相同则只记录、不重写。
    func applyRemote(_ text: String) {
        lastSyncedText = text               // 记为已同步内容 → poll 看到它不会回推
        if pb.string(forType: .string) == text { return }
        pb.clearContents()
        pb.setString(text, forType: .string)
        lastChangeCount = pb.changeCount
    }
}
