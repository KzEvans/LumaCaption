import AppKit
import FlutterMacOS

/// Native window chrome stays beside Flutter, with independent accessibility.
final class GlassChromeController: NSObject {
    private let channel: FlutterMethodChannel
    private let views = NSHashTable<ChromeView>.weakObjects()
    private var state: [String: Any] = [:]

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "lumacaption/design", binaryMessenger: messenger)
        super.init()
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self else { return }
            switch call.method {
            case "sync":
                self.state = call.arguments as? [String: Any] ?? [:]
                let theme = self.state["theme"] as? String ?? "system"
                NSApp.windows.first(where: { $0.title == "LumaCaption" })?.appearance =
                    theme == "dark" ? NSAppearance(named: .darkAqua) :
                    theme == "light" ? NSAppearance(named: .aqua) : nil
                for view in self.views.allObjects { view.update(self.state) }
                result(nil)
            case "status":
                result([
                    "reduceTransparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                    "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                    "views": self.views.allObjects.map { $0.status() },
                ])
            default: result(FlutterMethodNotImplemented)
            }
        }
    }
    func create(role: String) -> NSView {
        let view = ChromeView(role: role) { [weak self] action, page in
            var value: [String: Any] = ["action": action]
            if let page { value["page"] = page }
            self?.channel.invokeMethod("action", arguments: value)
        }
        views.add(view); view.update(state)
        return view
    }
}

private final class GlassSurface: NSView {
    let content = NSView()
    private var effect: NSView?
    private var observer: NSObjectProtocol?
    var materialName: String { effect.map { String(describing: type(of: $0)) } ?? "none" }
    override init(frame: NSRect) {
        super.init(frame: frame)
        rebuild()
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.rebuild() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }
    private func rebuild() {
        content.removeFromSuperview(); effect?.removeFromSuperview()
        let background: NSView
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let solid = NSView(); solid.wantsLayer = true
            solid.layer?.cornerRadius = 16
            background = solid
        } else if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular; glass.cornerRadius = 16
            glass.contentView = content
            background = glass
        } else {
            let visual = NSVisualEffectView()
            visual.material = .sidebar; visual.blendingMode = .behindWindow; visual.state = .followsWindowActiveState
            visual.wantsLayer = true; visual.layer?.cornerRadius = 16
            background = visual
        }
        effect = background; addSubview(background)
        background.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor), background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor), background.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        if content.superview == nil { background.addSubview(content) }
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor), content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            content.topAnchor.constraint(equalTo: background.topAnchor), content.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        updateSolidColor()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateSolidColor() }
    private func updateSolidColor() {
        guard NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance { effect?.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
    }
}

private final class ChromeView: NSView {
    private let role: String
    private let action: (String, Int?) -> Void
    private let glass = GlassSurface(frame: .zero)
    private let title = NSTextField(labelWithString: "LumaCaption")
    private var navigation: [NSButton] = []
    private var start: NSButton?
    private var overlay: NSButton?
    private var selectedPage = 0
    private let labels = ["实时字幕", "模型管理", "翻译服务", "字幕外观", "历史与导出", "设置与诊断"]
    private let symbols = ["captions.bubble", "cpu", "character.bubble", "textformat", "clock.arrow.circlepath", "slider.horizontal.3"]

    init(role: String, action: @escaping (String, Int?) -> Void) {
        self.role = role; self.action = action
        super.init(frame: .zero)
        if role == "navigation" { buildNavigation() } else { buildToolbar() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func pin(_ view: NSView, to parent: NSView, inset: CGFloat) {
        parent.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset), view.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            view.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset), view.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset),
        ])
    }
    private func buildNavigation() {
        pin(glass, to: self, inset: 12)
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        pin(stack, to: glass.content, inset: 12)
        let brand = NSTextField(labelWithString: "LumaCaption")
        brand.font = .systemFont(ofSize: 18, weight: .semibold)
        stack.addArrangedSubview(brand)
        let subtitle = NSTextField(labelWithString: "让理解，跟上声音。")
        subtitle.font = .systemFont(ofSize: 11); subtitle.textColor = .secondaryLabelColor
        stack.addArrangedSubview(subtitle)
        let gap = NSView(); gap.heightAnchor.constraint(equalToConstant: 16).isActive = true; stack.addArrangedSubview(gap)
        for i in labels.indices {
            let button = NSButton(title: labels[i], target: self, action: #selector(navigate(_:)))
            button.tag = i; button.setButtonType(.pushOnPushOff); button.bezelStyle = .recessed
            button.alignment = .left; button.font = .systemFont(ofSize: 13)
            button.image = NSImage(systemSymbolName: symbols[i], accessibilityDescription: nil)
            button.imagePosition = .imageLeading; button.imageHugsTitle = false
            button.setAccessibilityLabel(labels[i]); button.toolTip = labels[i]
            button.heightAnchor.constraint(equalToConstant: 40).isActive = true
            navigation.append(button); stack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let space = NSView(); space.setContentHuggingPriority(.defaultLow, for: .vertical); stack.addArrangedSubview(space)
        let footer = NSTextField(labelWithString: "桌面版 0.1.0")
        footer.font = .systemFont(ofSize: 11); footer.textColor = .secondaryLabelColor
        stack.addArrangedSubview(footer)
    }
    private func buildToolbar() {
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let startButton = NSButton(title: "开始字幕", target: self, action: #selector(toggleStart))
        startButton.bezelStyle = .rounded; startButton.bezelColor = .controlAccentColor
        startButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        startButton.imagePosition = .imageLeading; startButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let overlayButton = NSButton(title: "打开悬浮窗", target: self, action: #selector(toggleOverlay))
        overlayButton.bezelStyle = .rounded
        overlayButton.image = NSImage(systemSymbolName: "pip", accessibilityDescription: nil)
        overlayButton.imagePosition = .imageLeading; overlayButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
        start = startButton; overlay = overlayButton
        let controls = NSStackView(views: [overlayButton, startButton]); controls.spacing = 8
        pin(controls, to: glass.content, inset: 8)
        let space = NSView(); space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [title, space, glass]); row.alignment = .centerY; row.spacing = 16
        pin(row, to: self, inset: 12)
    }
    @objc private func navigate(_ sender: NSButton) { action("navigate", sender.tag) }
    @objc private func toggleStart() { action("toggleStart", nil) }
    @objc private func toggleOverlay() { action("toggleOverlay", nil) }
    func update(_ values: [String: Any]) {
        selectedPage = max(0, min(5, values["page"] as? Int ?? 0))
        for button in navigation {
            button.state = button.tag == selectedPage ? .on : .off
            button.isBordered = button.tag == selectedPage
        }
        title.stringValue = labels[selectedPage]
        let running = values["running"] as? Bool ?? false
        start?.title = running ? "停止字幕" : "开始字幕"
        start?.image = NSImage(systemSymbolName: running ? "stop.fill" : "play.fill", accessibilityDescription: nil)
        start?.isEnabled = !(values["busy"] as? Bool ?? false)
        overlay?.title = values["overlayVisible"] as? Bool ?? false ? "隐藏悬浮窗" : "打开悬浮窗"
    }
    func status() -> [String: Any] {
        ["role": role, "material": glass.materialName, "page": selectedPage,
         "buttons": navigation.count + (start == nil ? 0 : 2),
         "width": bounds.width, "height": bounds.height, "attached": window != nil]
    }
}
