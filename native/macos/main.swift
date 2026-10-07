import AppKit
import FlutterMacOS

@available(macOS 13.3, *)
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var bridge: NativeBridge!
    var design: WorkbenchController!
    var backend: FlutterEngine!
    func applicationDidFinishLaunching(_ notification: Notification) {
        backend = FlutterEngine(name: "LumaCaption.backend", project: FlutterDartProject(precompiledDartBundle: nil), allowHeadlessExecution: true)
        bridge = NativeBridge(messenger: backend.binaryMessenger)
        design = WorkbenchController(messenger: backend.binaryMessenger)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "LumaCaption"; window.minSize = NSSize(width: 860, height: 650)
        window.contentViewController = design.root; window.delegate = self; window.isReleasedWhenClosed = false
        design.attach(to: window)
        bridge.mainWindow = window
        backend.run(withEntrypoint: nil)
        window.setFrameAutosaveName("LumaCaption.main"); window.center()
        bridge.overlay.showMainWindow = { [weak self] in self?.window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        setupMenu()
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func setupMenu() {
        let menu = NSMenu(); let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 LumaCaption", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "设置…", action: #selector(WorkbenchController.settingsPage), keyEquivalent: ","); settings.target = design
        appMenu.addItem(.separator()); appMenu.addItem(withTitle: "隐藏 LumaCaption", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 LumaCaption", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); menu.addItem(editItem); let edit = NSMenu(title: "编辑"); editItem.submenu = edit
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z"); redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"); edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c"); edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"); edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let find = edit.addItem(withTitle: "查找…", action: #selector(WorkbenchController.find), keyEquivalent: "f"); find.target = design
        let captionItem = NSMenuItem(); menu.addItem(captionItem); let captions = NSMenu(title: "字幕"); captionItem.submenu = captions
        for (title, action, key) in [("开始 / 停止字幕", #selector(WorkbenchController.toggleStart), "\r"), ("暂停 / 继续", #selector(WorkbenchController.pause), "p"), ("显示 / 隐藏悬浮字幕", #selector(WorkbenchController.toggleOverlay), "l"), ("立即停止", #selector(WorkbenchController.emergency), ".")] {
            let item = captions.addItem(withTitle: title, action: action, keyEquivalent: key); item.target = design
        }
        let viewItem = NSMenuItem(); menu.addItem(viewItem); let viewMenu = NSMenu(title: "显示"); viewItem.submenu = viewMenu
        let sidebar = viewMenu.addItem(withTitle: "显示 / 隐藏侧边栏", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s"); sidebar.target = design.root; sidebar.keyEquivalentModifierMask = [.command, .control]
        let fullScreen = viewMenu.addItem(withTitle: "进入 / 退出全屏", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f"); fullScreen.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(.separator())
        for (i, title) in design.titles.enumerated() { let item = viewMenu.addItem(withTitle: title, action: #selector(WorkbenchController.goPage(_:)), keyEquivalent: String(i + 1)); item.tag = i; item.target = design }
        let windowItem = NSMenuItem(); menu.addItem(windowItem); let windows = NSMenu(title: "窗口"); windowItem.submenu = windows
        windows.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windows.addItem(withTitle: "全部置于前方", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windows
        NSApp.mainMenu = menu
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.orderOut(nil); return false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { bridge?.shutdown(); backend?.shutDownEngine() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { window.makeKeyAndOrderFront(nil); return true }
}
let application = NSApplication.shared
application.setActivationPolicy(.regular)
let delegate = AppDelegate()
application.delegate = delegate
application.run()
