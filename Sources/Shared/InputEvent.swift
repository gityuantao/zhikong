import Foundation

/// 输入事件 —— Client→Host 反向通道的载荷(方向即类型,与视频帧区分)。
///
/// 坐标在 Client 端已归一化到 0..1(相对视频内容区,letterbox 校正后),
/// Host 端再映射回主显示器像素注入。
///
/// 线格式:`tag(1B) | 各分支字段`。
/// - `mouseMove(nx,ny)`   tag=1:nx(Float64 大端) + ny(Float64 大端)
/// - `mouseButton(button,down)` tag=2:button(1B) + down(1B,0/1)
/// - `scroll(dx,dy)`      tag=3:dx(Float64 大端) + dy(Float64 大端)
/// - `key(keyCode,down,modifiers)` tag=4:keyCode(2B 大端) + down(1B) + modifiers(8B 大端)
/// - `switchSpace(left)`  tag=5:left(1B,0/1)。一次完整水平手势的离散「切桌面」意图,
///   方向 left=左/右,Host 端映射到 Ctrl+←/→(via AppleScript)。
/// - `missionControl(up)` tag=6:up(1B,0/1)。一次完整**垂直**手势:up=上划→调度中心(Ctrl+↑),
///   下划→应用窗口/App Exposé(Ctrl+↓),Host 端经 System Events 代发。
///
/// Float64 经 `bitPattern` 转 UInt64 再大端写,跨机字节序确定。
enum InputEvent: Equatable {
    case mouseMove(nx: Double, ny: Double)
    case mouseButton(button: UInt8, down: Bool)
    case scroll(dx: Double, dy: Double)
    case key(keyCode: UInt16, down: Bool, modifiers: UInt64)
    case switchSpace(left: Bool)
    case missionControl(up: Bool)

    private enum Tag: UInt8 {
        case mouseMove = 1
        case mouseButton = 2
        case scroll = 3
        case key = 4
        case switchSpace = 5
        case missionControl = 6
    }

    // MARK: - Encode

    func encode() -> Data {
        var out = Data()
        switch self {
        case .mouseMove(let nx, let ny):
            out.append(Tag.mouseMove.rawValue)
            out.appendBigEndian(nx.bitPattern)
            out.appendBigEndian(ny.bitPattern)
        case .mouseButton(let button, let down):
            out.append(Tag.mouseButton.rawValue)
            out.append(button)
            out.append(down ? 1 : 0)
        case .scroll(let dx, let dy):
            out.append(Tag.scroll.rawValue)
            out.appendBigEndian(dx.bitPattern)
            out.appendBigEndian(dy.bitPattern)
        case .key(let keyCode, let down, let modifiers):
            out.append(Tag.key.rawValue)
            out.appendBigEndian(keyCode)
            out.append(down ? 1 : 0)
            out.appendBigEndian(modifiers)
        case .switchSpace(let left):
            out.append(Tag.switchSpace.rawValue)
            out.append(left ? 1 : 0)
        case .missionControl(let up):
            out.append(Tag.missionControl.rawValue)
            out.append(up ? 1 : 0)
        }
        return out
    }

    // MARK: - Decode

    /// 坏 tag / 截断(任何字段读不全)/ 尾部残留,一律返回 nil(绝不越界读)。
    static func decode(_ data: Data) -> InputEvent? {
        var reader = ByteReader(data)
        guard let tagRaw = reader.readUInt8(), let tag = Tag(rawValue: tagRaw) else { return nil }

        let event: InputEvent
        switch tag {
        case .mouseMove:
            guard let nxBits = reader.readUInt64BE(), let nyBits = reader.readUInt64BE() else { return nil }
            event = .mouseMove(nx: Double(bitPattern: nxBits), ny: Double(bitPattern: nyBits))
        case .mouseButton:
            guard let button = reader.readUInt8(), let downRaw = reader.readUInt8() else { return nil }
            event = .mouseButton(button: button, down: downRaw != 0)
        case .scroll:
            guard let dxBits = reader.readUInt64BE(), let dyBits = reader.readUInt64BE() else { return nil }
            event = .scroll(dx: Double(bitPattern: dxBits), dy: Double(bitPattern: dyBits))
        case .key:
            guard let keyCode = reader.readUInt16BE(),
                  let downRaw = reader.readUInt8(),
                  let modifiers = reader.readUInt64BE() else { return nil }
            event = .key(keyCode: keyCode, down: downRaw != 0, modifiers: modifiers)
        case .switchSpace:
            guard let leftRaw = reader.readUInt8() else { return nil }
            event = .switchSpace(left: leftRaw != 0)
        case .missionControl:
            guard let upRaw = reader.readUInt8() else { return nil }
            event = .missionControl(up: upRaw != 0)
        }

        // 必须恰好消耗完(防止多塞字节当成有效帧)。
        guard reader.isAtEnd else { return nil }
        return event
    }
}

// MARK: - 大端写入辅助

private extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }
    mutating func appendBigEndian(_ value: UInt64) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }
}

// MARK: - 边界安全的字节读取器(大端)

/// 顺序游标读取器。所有读取在越界时返回 nil,从不触发越界访问。
private struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    var isAtEnd: Bool { offset == data.endIndex }

    private var remaining: Int { data.endIndex - offset }

    mutating func readBytes(_ count: Int) -> Data? {
        guard count >= 0, count <= remaining else { return nil }
        let start = offset
        let end = offset + count
        offset = end
        return Data(data[start..<end])
    }

    mutating func readUInt8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        let value = data[offset]
        offset += 1
        return value
    }

    mutating func readUInt16BE() -> UInt16? {
        guard let bytes = readBytes(2) else { return nil }
        return bytes.withUnsafeBytes { raw in
            raw.loadUnaligned(as: UInt16.self).bigEndian
        }
    }

    mutating func readUInt64BE() -> UInt64? {
        guard let bytes = readBytes(8) else { return nil }
        return bytes.withUnsafeBytes { raw in
            raw.loadUnaligned(as: UInt64.self).bigEndian
        }
    }
}
