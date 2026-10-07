import AppKit
import FlutterMacOS

@available(macOS 13.3, *)
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var bridge: NativeBridge!
    var design: GlassChromeFactory!
    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = FlutterViewController(project: FlutterDartProject(precompiledDartBundle: nil))
        controller.backgroundColor = .clear
        design = GlassChromeFactory(messenger: controller.engine.binaryMessenger)
        controller.engine.registrar(forPlugin: "LumaGlassChrome").register(design, withId: "lumacaption/glass-chrome")
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "LumaCaption"; window.minSize = NSSize(width: 860, height: 650)
        window.contentViewController = controller; window.delegate = self; window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("LumaCaption.main"); window.center()
        bridge = NativeBridge(messenger: controller.engine.binaryMessenger)
        bridge.overlay.showMainWindow = { [weak self] in self?.window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        setupMenu()
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func setupMenu() {
        let menu = NSMenu(); let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 LumaCaption", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator()); appMenu.addItem(withTitle: "隐藏 LumaCaption", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 LumaCaption", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); menu.addItem(editItem); let edit = NSMenu(title: "编辑"); editItem.submenu = edit
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"); edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c"); edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"); edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = menu
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.orderOut(nil); return false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { bridge?.shutdown() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { window.makeKeyAndOrderFront(nil); return true }
}
let application = NSApplication.shared
application.setActivationPolicy(.regular)
let delegate = AppDelegate()
application.delegate = delegate
application.run()
