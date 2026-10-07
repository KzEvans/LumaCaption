import AppKit
import Carbon

private final class CaptionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class CaptionView: NSView {
    let original = NSTextField(wrappingLabelWithString: "")
    let translation = NSTextField(wrappingLabelWithString: "")
    let hint = NSTextField(labelWithString: "LumaCaption · 拖动移动 · 右下角调整大小")
    let glass = LiquidGlassSurface(frame: .zero)
    var backgroundOpacity: CGFloat = 0.78 { didSet { glass.materialOpacity = backgroundOpacity } }
    private var resizeOrigin: NSPoint?
    private var resizeFrame: NSRect?
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        pin(glass, in: self)
        for label in [hint, original, translation] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.isSelectable = false
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 3
            addSubview(label)
        }
        hint.font = .systemFont(ofSize: 10, weight: .medium)
        hint.textColor = .secondaryLabelColor
        original.textColor = .secondaryLabelColor
        translation.textColor = .labelColor
        original.font = .systemFont(ofSize: 21, weight: .medium)
        translation.font = .systemFont(ofSize: 26, weight: .semibold)
        let grip = nativeSymbol("arrow.up.left.and.arrow.down.right", size: 10)
        addSubview(grip); grip.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            grip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            grip.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            hint.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            original.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 10),
            original.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            original.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            translation.topAnchor.constraint(equalTo: original.bottomAnchor, constant: 8),
            translation.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            translation.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            translation.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -18)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    // Captions are passive text. Keep the entire glass surface draggable,
    // including its material and label subviews; the panel handles click-through.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.x > bounds.width - 28, point.y > bounds.height - 28 {
            resizeOrigin = NSEvent.mouseLocation
            resizeFrame = window?.frame
        } else { window?.performDrag(with: event) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let origin = resizeOrigin, let frame = resizeFrame, let window else { return }
        let current = NSEvent.mouseLocation
        let width = max(280, frame.width + current.x - origin.x)
        let height = max(110, frame.height - current.y + origin.y)
        window.setFrame(NSRect(x: frame.minX, y: frame.maxY - height, width: width, height: height), display: true)
    }
    override func mouseUp(with event: NSEvent) { resizeOrigin = nil; resizeFrame = nil }
}

final class OverlayController: NSObject, NSWindowDelegate {
    private let panel: CaptionPanel
    private let captions = CaptionView(frame: NSRect(x: 0, y: 0, width: 760, height: 180))
    private var statusItem: NSStatusItem!
    private var displayObserver: NSObjectProtocol?
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var original = ""
    private var translation = ""
    private var display = "bilingual"
    var onCommand: ((String) -> Void)?
    var showMainWindow: (() -> Void)?

    override init() {
        panel = CaptionPanel(contentRect: NSRect(x: 180, y: 100, width: 760, height: 180), styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = "LumaCaption 悬浮字幕"
        panel.contentView = captions
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 280, height: 110)
        panel.delegate = self
        if let saved = UserDefaults.standard.string(forKey: "overlay.frame") { panel.setFrame(NSRectFromString(saved), display: false) }
        restoreOnScreen()
        setupStatusItem()
        setupRecoveryShortcut(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(cmdKey | optionKey | controlKey))
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.restoreOnScreen() }
    }

    func show() { restoreOnScreen(); panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }
    func status() -> [String: Any] {
        ["visible": panel.isVisible, "clickThrough": panel.ignoresMouseEvents,
         "isKeyWindow": panel.isKeyWindow, "canBecomeKey": panel.canBecomeKey,
         "opaque": panel.isOpaque, "shortcutRegistered": hotKey != nil,
         "width": panel.frame.width, "height": panel.frame.height, "material": captions.glass.materialName]
    }
    func update(original: String, translation: String) {
        self.original = original
        self.translation = translation
        renderText()
    }
    func configure(_ options: [String: Any]) {
        if let theme = options["theme"] as? String {
            panel.appearance = theme == "dark" ? NSAppearance(named: .darkAqua) : theme == "light" ? NSAppearance(named: .aqua) : nil
        }
        if let value = options["fontSize"] as? NSNumber {
            let size = CGFloat(max(12, min(72, value.doubleValue)))
            captions.original.font = .systemFont(ofSize: size * 0.8, weight: .medium)
            captions.translation.font = .systemFont(ofSize: size, weight: .semibold)
        }
        if let value = options["opacity"] as? NSNumber { captions.backgroundOpacity = CGFloat(max(0, min(1, value.doubleValue))) }
        if let value = options["display"] as? String, ["bilingual", "original", "translation"].contains(value) { display = value }
        if let value = options["clickThrough"] as? Bool {
            panel.ignoresMouseEvents = value
            captions.hint.stringValue = value ? "LumaCaption · 菜单栏或 ⌃⌥⌘L 恢复交互" : "LumaCaption · 拖动移动 · 右下角调整大小"
            captions.needsDisplay = true
        }
        if let keyCode = options["shortcutKeyCode"] as? NSNumber, let modifiers = options["shortcutModifiers"] as? NSNumber {
            setupRecoveryShortcut(keyCode: keyCode.uint32Value, modifiers: modifiers.uint32Value)
        }
        renderText()
    }

    private func renderText() {
        captions.original.stringValue = display == "translation" ? "" : original
        captions.translation.stringValue = display == "original" ? "" : translation
        panel.contentView?.needsLayout = true
    }

    @objc func recoverInteraction() {
        panel.ignoresMouseEvents = false
        captions.hint.stringValue = "LumaCaption · 拖动移动 · 右下角调整大小"
        captions.needsDisplay = true
        show()
        onCommand?("overlayRecovered")
    }
    @objc private func resetPosition() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrame(NSRect(x: frame.midX - 380, y: frame.minY + 72, width: 760, height: 180), display: true)
        recoverInteraction()
    }
    @objc private func openMain() { showMainWindow?() }
    @objc private func beginCapture() { onCommand?("start") }
    @objc private func stopCapture() { onCommand?("stop") }
    @objc private func showOverlay() { show() }
    @objc private func hideOverlay() { hide() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "captions.bubble.fill", accessibilityDescription: "LumaCaption")
        statusItem.button?.toolTip = "LumaCaption 实时翻译字幕"
        let menu = NSMenu(title: "LumaCaption")
        let entries: [(String, Selector?)] = [
            ("打开 LumaCaption", #selector(openMain)), ("", nil),
            ("开始字幕", #selector(beginCapture)), ("停止字幕", #selector(stopCapture)),
            ("显示悬浮字幕", #selector(showOverlay)), ("隐藏悬浮字幕", #selector(hideOverlay)),
            ("恢复悬浮窗交互（⌃⌥⌘L）", #selector(recoverInteraction)),
            ("重置悬浮窗位置", #selector(resetPosition)), ("", nil), ("退出 LumaCaption", #selector(quit))
        ]
        for (title, selector) in entries {
            if let selector {
                let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            } else { menu.addItem(.separator()) }
        }
        statusItem.menu = menu
    }

    private func setupRecoveryShortcut(keyCode: UInt32, modifiers: UInt32) {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if eventHandler == nil {
            var specification = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let context = Unmanaged.passUnretained(self).toOpaque()
            InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
                guard let context else { return OSStatus(eventNotHandledErr) }
                let controller = Unmanaged<OverlayController>.fromOpaque(context).takeUnretainedValue()
                DispatchQueue.main.async { controller.recoverInteraction() }
                return noErr
            }, 1, &specification, context, &eventHandler)
        }
        let identifier = EventHotKeyID(signature: OSType(0x4C554D41), id: 1)
        RegisterEventHotKey(keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &hotKey)
    }

    private func restoreOnScreen() {
        let screens = NSScreen.screens
        guard let screen = screens.first(where: { $0.visibleFrame.intersection(panel.frame).width >= 100 && $0.visibleFrame.intersection(panel.frame).height >= 60 }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = panel.frame
        frame.size.width = min(max(frame.width, 280), visible.width)
        frame.size.height = min(max(frame.height, 110), visible.height)
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        panel.setFrame(frame, display: true)
    }
    func windowDidMove(_ notification: Notification) { savePosition() }
    func windowDidResize(_ notification: Notification) { savePosition() }
    private func savePosition() {
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: "overlay.frame")
        if let id = panel.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: "overlay.frame.\(id)")
        }
    }
    func dispose() {
        panel.orderOut(nil)
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item); statusItem = nil }
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if let eventHandler { RemoveEventHandler(eventHandler); self.eventHandler = nil }
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver); self.displayObserver = nil }
    }
    deinit { dispose() }
}
