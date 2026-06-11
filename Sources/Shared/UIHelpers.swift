import AppKit

/// 统一的「文字链接」(灰色),两端窗口共用——如「‹ 切换角色」。
///
/// 用**可点击的 NSTextField(label)** 而非 NSButton:label 文字从 `frame.x` 精确起笔、无按钮内边距,
/// 因此能与下方内容(远控码 / 输入框)做到**像素级左对齐**。点击经 NSClickGestureRecognizer 触发。
func makeLinkLabel(_ title: String, target: AnyObject, action: Selector) -> NSTextField {
    let l = NSTextField(labelWithString: title)
    l.font = .systemFont(ofSize: 12)
    l.textColor = .secondaryLabelColor
    l.alignment = .left
    l.addGestureRecognizer(NSClickGestureRecognizer(target: target, action: action))
    return l
}
