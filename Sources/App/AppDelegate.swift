import AppKit

/// 单 app 顶层委托:启动先弹**角色选择**(控制端 / 被控端),选后启动对应控制器。
/// 两端合一——一次安装、一套权限、一个 bundle。底层(加密/分帧/音频/协议)本就共用。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var roleWindow: NSWindow!
    private var host: HostController?
    private var client: ClientController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 可用 env 跳过角色选择直接进入(如常驻被控端开机自启):ZHIKONG_ROLE=host / client。
        switch ProcessInfo.processInfo.environment["ZHIKONG_ROLE"] {
        case "host":   startHost()
        case "client": startClient()
        default:       showRolePicker()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 角色选择

    private func showRolePicker() {
        if roleWindow == nil {
            let w: CGFloat = 420, h: CGFloat = 230
            roleWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            roleWindow.title = "直控"
            roleWindow.isReleasedWhenClosed = false

            let title = NSTextField(labelWithString: "这台 Mac 当作")
            title.font = .systemFont(ofSize: 16, weight: .semibold)
            title.alignment = .center
            title.frame = NSRect(x: 0, y: h - 52, width: w, height: 24)
            roleWindow.contentView?.addSubview(title)

            let clientBtn = makeRoleButton("控制端", "远程控制别的 Mac", #selector(pickClient), y: h - 132)
            roleWindow.contentView?.addSubview(clientBtn)
            let hostBtn = makeRoleButton("被控端", "把这台屏幕分享出去、被远程控制", #selector(pickHost), y: 28)
            roleWindow.contentView?.addSubview(hostBtn)
        }
        roleWindow.center()
        roleWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeRoleButton(_ name: String, _ subtitle: String, _ action: Selector, y: CGFloat) -> NSButton {
        let b = NSButton(title: "", target: self, action: action)
        b.bezelStyle = .regularSquare
        b.frame = NSRect(x: 40, y: y, width: 340, height: 64)
        let para = NSMutableParagraphStyle(); para.alignment = .center; para.lineSpacing = 3
        let s = NSMutableAttributedString(string: name + "\n",
            attributes: [.font: NSFont.systemFont(ofSize: 16, weight: .semibold), .paragraphStyle: para])
        s.append(NSAttributedString(string: subtitle,
            attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para]))
        b.attributedTitle = s
        return b
    }

    @objc private func pickClient() { startClient() }
    @objc private func pickHost() { startHost() }

    private func startClient() {
        roleWindow?.orderOut(nil)
        let c = ClientController(); client = c
        c.onSwitchRole = { [weak self] in self?.switchRole() }
        c.start()
    }
    private func startHost() {
        roleWindow?.orderOut(nil)
        let hc = HostController(); host = hc
        hc.onSwitchRole = { [weak self] in self?.switchRole() }
        hc.start()
    }

    /// 从当前角色返回选择窗:停掉并释放当前角色,重新展示角色选择(控制器已先 orderOut 自己的窗口)。
    private func switchRole() {
        host?.stop(); host = nil
        client?.stop(); client = nil
        showRolePicker()
    }

    // MARK: - 生命周期(按所选角色分派)

    func applicationWillTerminate(_ notification: Notification) {
        host?.stop()
        client?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 被控端常驻(关窗不退,仍在后台推流);控制端非常驻(关连接窗=退);未选角色时关掉即退。
        if let host { return !host.staysResidentOnWindowClose }
        if let client { return !client.staysResidentOnWindowClose }
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let host { host.showWindow() }
            else if client == nil { roleWindow.makeKeyAndOrderFront(nil) }
        }
        return true
    }
}
