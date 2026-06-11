import AppKit

/// 统一的「文字链接」按钮(灰色、无边框),两端窗口共用风格——如「‹ 切换角色」。
func makeLinkButton(_ title: String, target: AnyObject, action: Selector) -> NSButton {
    let b = NSButton(title: title, target: target, action: action)
    b.isBordered = false
    b.bezelStyle = .inline
    b.attributedTitle = NSAttributedString(string: title, attributes: [
        .foregroundColor: NSColor.secondaryLabelColor,
        .font: NSFont.systemFont(ofSize: 12),
    ])
    return b
}
