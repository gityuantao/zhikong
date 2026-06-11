import AppKit

/// 最小主菜单 —— 两个 app 之前都没设 `NSApp.mainMenu`,导致 Cmd+Q 等标准快捷键无处可投、不生效。
/// 提供「应用名 ▸ 隐藏/退出」+「窗口 ▸ 最小化/缩放」,让鼠标点退出与 Cmd+Q(未被键盘捕获消费时)可用。
///
/// 注意:Client 远程聚焦时,`SystemKeyCapture` 会在会话流最前消费 Cmd+Q 并转发给被控机,
/// 故此时 Cmd+Q 不会退出本机 Client —— 用菜单鼠标点「退出」即可(或先切走焦点再 Cmd+Q)。
/// Host 不捕获键盘,Cmd+Q 正常退出。
enum AppMenu {
    static func install(appName: String) {
        let mainMenu = NSMenu()

        // 应用菜单(第一项,标题由系统替换为应用名)。
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "隐藏\(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "退出\(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // 窗口菜单(最小化/缩放/前置)。
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }
}
