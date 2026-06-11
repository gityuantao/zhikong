import Foundation

/// 远控码生成 —— 被控端每次(或点刷新)生成一个随机、易读、不写死的码。
/// 字母表去掉易混字符(0/O/1/I/L),全大写;6 位 ≈ 30bit,作为会话级配对码足够,
/// 且**每次刷新即换**(旧码立即失效),比固定码更安全。
enum RoomCode {
    private static let alphabet = Array("23456789ABCDEFGHJKMNPQRSTUVWXYZ")

    static func generate(length: Int = 6) -> String {
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] })
    }

    /// 规范化用户输入:去空格、转大写(与生成保持一致,避免大小写不匹配连不上)。
    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}
