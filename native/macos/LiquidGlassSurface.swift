import AppKit

final class LiquidGlassSurface: NSView {
    let content = NSView()
    private var effect: NSView?
    private var observer: NSObjectProtocol?
    var materialOpacity: CGFloat = 1 { didSet { effect?.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1 : materialOpacity } }
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
        effect?.removeFromSuperview()
        let background: NSView
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let solid = NSView(); solid.wantsLayer = true
            solid.layer?.cornerRadius = MacUI.cornerRadius
            background = solid
        } else if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular; glass.cornerRadius = MacUI.cornerRadius
            background = glass
        } else {
            let visual = NSVisualEffectView()
            visual.material = .hudWindow; visual.blendingMode = .behindWindow; visual.state = .followsWindowActiveState
            visual.wantsLayer = true; visual.layer?.cornerRadius = MacUI.cornerRadius
            visual.layer?.masksToBounds = true
            background = visual
        }
        effect = background; addSubview(background, positioned: .below, relativeTo: content.superview == self ? content : nil)
        background.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor), background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor), background.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        if content.superview == nil { addSubview(content) }
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor), content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        background.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1 : materialOpacity
        updateSolidColor()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateSolidColor() }
    private func updateSolidColor() {
        guard NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance { effect?.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
    }
}
