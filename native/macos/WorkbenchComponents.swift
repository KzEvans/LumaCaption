import AppKit

enum MacUI {
    // App-owned surfaces share a restrained rounded rectangle. Window controls
    // and standard switches, menus and fields keep their system geometry.
    static let cornerRadius: CGFloat = 10
    static let headingSize: CGFloat = 28
    static func textColor(on fill: NSColor) -> NSColor {
        guard let rgb = fill.usingColorSpace(.sRGB) else { return .controlTextColor }
        func linear(_ value: CGFloat) -> CGFloat { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        return luminance > 0.179 ? .black : .white
    }
}

func nativeLabel(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .systemFont(ofSize: size, weight: weight)
    label.textColor = secondary ? .secondaryLabelColor : .labelColor
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
}
func nativeSymbol(_ name: String, size: CGFloat = 18) -> NSImageView {
    let view = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
    view.symbolConfiguration = .init(pointSize: size, weight: .regular)
    view.contentTintColor = .secondaryLabelColor
    view.setAccessibilityElement(false)
    return view
}
func row(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
    let stack = NSStackView(views: views); stack.orientation = .horizontal
    stack.alignment = .centerY; stack.spacing = spacing; return stack
}
func column(_ views: [NSView] = [], spacing: CGFloat = 12) -> NSStackView {
    let stack = NSStackView(views: views); stack.orientation = .vertical
    stack.alignment = .leading; stack.spacing = spacing; return stack
}
func spacer() -> NSView {
    let view = NSView(); view.setContentHuggingPriority(.defaultLow, for: .horizontal); return view
}
func pin(_ child: NSView, in parent: NSView, inset: CGFloat = 0) {
    parent.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
        child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
        child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
        child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset),
    ])
}
private final class RoundedActionCell: NSButtonCell {
    override func drawBezel(withFrame frame: NSRect, in controlView: NSView) {
        let rect = frame.insetBy(dx: 1, dy: 1)
        let shape = NSBezierPath(roundedRect: rect, xRadius: MacUI.cornerRadius, yRadius: MacUI.cornerRadius)
        let accent = (controlView as? NSButton)?.bezelColor
        let fill = accent ?? .controlBackgroundColor
        (isEnabled ? fill : fill.withAlphaComponent(0.45)).setFill(); shape.fill()
        if isHighlighted { NSColor.labelColor.withAlphaComponent(0.12).setFill(); shape.fill() }
        if accent == nil { NSColor.separatorColor.setStroke(); shape.lineWidth = 0.5; shape.stroke() }
    }
    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        let styled = NSMutableAttributedString(attributedString: title)
        let foreground = (controlView as? NSButton)?.bezelColor.map(MacUI.textColor(on:)) ?? .controlTextColor
        styled.addAttribute(.foregroundColor, value: isEnabled ? foreground : NSColor.disabledControlTextColor, range: NSRange(location: 0, length: styled.length))
        return super.drawTitle(styled, withFrame: frame, in: controlView)
    }
    override func drawFocusRingMask(withFrame frame: NSRect, in controlView: NSView) {
        NSBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 1), xRadius: MacUI.cornerRadius, yRadius: MacUI.cornerRadius).fill()
    }
}

final class ActionButton: NSButton {
    var perform: (() -> Void)?
    init(_ title: String, symbol: String? = nil, perform: @escaping () -> Void) {
        super.init(frame: .zero); cell = RoundedActionCell(textCell: title)
        self.title = title; self.perform = perform
        bezelStyle = .rounded; controlSize = .large; font = .systemFont(ofSize: 13)
        setButtonType(.momentaryPushIn); target = self; action = #selector(pressed)
        heightAnchor.constraint(equalToConstant: 34).isActive = true
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); imagePosition = .imageLeading }
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func pressed() { perform?() }
}
final class ChoiceControl: NSPopUpButton {
    var values: [String]; var changed: ((String) -> Void)?
    init(_ choices: [(String, String)], changed: @escaping (String) -> Void) {
        values = choices.map { $0.0 }; super.init(frame: .zero, pullsDown: false)
        addItems(withTitles: choices.map { $0.1 }); self.changed = changed
        target = self; action = #selector(picked)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func picked() { if values.indices.contains(indexOfSelectedItem) { changed?(values[indexOfSelectedItem]) } }
    func selectValue(_ value: String) { if let i = values.firstIndex(of: value) { selectItem(at: i) } }
}
final class ToggleControl: NSSwitch {
    var changed: ((Bool) -> Void)?
    init(_ label: String, changed: @escaping (Bool) -> Void) {
        super.init(frame: .zero); self.changed = changed; target = self; action = #selector(flipped)
        setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func flipped() { changed?(state == .on) }
}
final class ValueSlider: NSSlider {
    var changed: ((Double) -> Void)?
    private(set) var tracking = false
    init(_ label: String, min: Double, max: Double, changed: @escaping (Double) -> Void) {
        super.init(frame: .zero); minValue = min; maxValue = max
        isContinuous = false; self.changed = changed; target = self; action = #selector(moved)
        setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func moved() { changed?(doubleValue) }
    override func mouseDown(with event: NSEvent) {
        tracking = true; defer { tracking = false }; super.mouseDown(with: event)
    }
}
final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// A continuous input meter with the same 10 pt contour as the app's surfaces.
/// Its semantic value remains available to VoiceOver without announcing every
/// audio sample as a live-region update.
final class InputLevelMeter: NSControl {
    private let fill = CALayer()
    private var level: Double = 0
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = MacUI.cornerRadius; layer?.masksToBounds = true
        fill.anchorPoint = NSPoint(x: 0, y: 0.5); fill.cornerRadius = MacUI.cornerRadius
        layer?.addSublayer(fill)
        setAccessibilityElement(true); setAccessibilityRole(.levelIndicator)
        setAccessibilityLabel("输入音量"); setAccessibilityMinValue(0); setAccessibilityMaxValue(100)
        setLevel(0); updateColors()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: 112, height: 20) }
    func setLevel(_ value: Double) {
        level = value.isFinite ? min(1, max(0, value)) : 0
        let percentage = Int((level * 100).rounded())
        setAccessibilityValue(percentage)
        setAccessibilityValueDescription("\(percentage)%")
        updateFill(animated: window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
    override func layout() { super.layout(); updateFill(animated: false) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }
    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.09).cgColor
            fill.backgroundColor = NSColor.systemGreen.cgColor
        }
    }
    private func updateFill(animated: Bool) {
        let previous = fill.presentation()?.bounds.width ?? fill.bounds.width
        let width = bounds.width * level
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.position = NSPoint(x: 0, y: bounds.midY)
        fill.bounds = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        CATransaction.commit()
        if animated {
            let transition = CABasicAnimation(keyPath: "bounds.size.width")
            transition.fromValue = previous; transition.toValue = width; transition.duration = 0.12
            transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fill.add(transition, forKey: "inputLevel")
        } else { fill.removeAnimation(forKey: "inputLevel") }
    }
}

/// Native selectable text, a find bar, and scroll preservation for streaming updates.
final class TranscriptView: NSView {
    let text = NSTextView()
    let scroll = NSScrollView()
    private let empty = column(spacing: 12)
    private let emptyTitle = nativeLabel("字幕，从这里开始", size: 22, weight: .semibold)
    private let emptyDetail = nativeLabel("选择声音来源与工作模式，准备好后开始字幕。", secondary: true)
    private var signature = ""
    init(history: Bool = false) {
        super.init(frame: .zero)
        text.isEditable = false; text.isSelectable = true; text.isRichText = true
        text.drawsBackground = false; text.textContainerInset = NSSize(width: 24, height: 22)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.usesFindBar = true; text.isIncrementalSearchingEnabled = true
        text.setAccessibilityLabel(history ? "字幕历史文本" : "实时字幕文本")
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.documentView = text
        pin(scroll, in: self)
        let icon = nativeSymbol(history ? "clock.arrow.circlepath" : "captions.bubble", size: 42)
        emptyTitle.alignment = .center; emptyDetail.alignment = .center
        if history { emptyTitle.stringValue = "还没有字幕历史"; emptyDetail.stringValue = "完成一段字幕后，可在这里查找、复制与导出。" }
        empty.alignment = .centerX
        for view in [icon, emptyTitle, emptyDetail] { empty.addArrangedSubview(view) }
        addSubview(empty); empty.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: centerXAnchor), empty.centerYAnchor.constraint(equalTo: centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ segments: [[String: Any]], display: String = "bilingual", autoscroll: Bool = false) {
        let data = (try? JSONSerialization.data(withJSONObject: [segments, display])) ?? Data()
        let key = data.base64EncodedString()
        guard key != signature else { return }; signature = key
        let atBottom = scroll.contentView.bounds.maxY >= text.bounds.height - 48
        let selection = text.selectedRange(), origin = scroll.contentView.bounds.origin
        let value = NSMutableAttributedString(string: "")
        for segment in segments {
            let time = (segment["startUs"] as? NSNumber).map { String(format: "%02d:%02d", $0.intValue / 60000000, ($0.intValue / 1000000) % 60) } ?? "实时"
            let confirmed = segment["final"] as? Bool ?? false
            let meta = "\(time)  ·  \(confirmed ? "已确认" : "识别中")\n"
            value.append(NSAttributedString(string: meta, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]))
            let original = segment["original"] as? String ?? "", translation = segment["translation"] as? String ?? ""
            if display != "translation", !original.isEmpty { append(original, size: display == "original" ? 20 : 17, to: value) }
            if display != "original", !translation.isEmpty { append(translation, size: 20, to: value) }
            if let error = segment["error"] as? String, !error.isEmpty { append(error, size: 12, to: value, color: .systemRed) }
            value.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 13)]))
        }
        text.textStorage?.setAttributedString(value)
        text.setSelectedRange(NSRange(location: min(selection.location, value.length), length: min(selection.length, max(0, value.length - selection.location))))
        empty.isHidden = !segments.isEmpty; scroll.isHidden = segments.isEmpty
        if autoscroll && atBottom { text.scrollRangeToVisible(NSRange(location: value.length, length: 0)) }
        else { scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView) }
    }
    private func append(_ string: String, size: CGFloat, to value: NSMutableAttributedString, color: NSColor = .labelColor) {
        let style = NSMutableParagraphStyle(); style.lineSpacing = 5; style.paragraphSpacing = 10
        value.append(NSAttributedString(string: string + "\n", attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color, .paragraphStyle: style]))
    }
}

class FormPage: NSViewController {
    let stack = column(spacing: 20)
    var controls: [String: NSControl] = [:]
    var details: [String: NSTextField] = [:]
    var send: (String, [String: Any]) -> Void = { _, _ in }
    var request: (String, [String: Any], @escaping (Bool) -> Void) -> Void = { _, _, completion in completion(false) }
    var state: [String: Any] = [:]
    var settings: [String: Any] { state["settings"] as? [String: Any] ?? [:] }
    override func loadView() {
        view = NSView()
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let document = FlippedView(); scroll.documentView = document; pin(scroll, in: view)
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -32),
        ])
    }
    func heading(_ title: String, detail: String) {
        let content = column([nativeLabel(title, size: MacUI.headingSize, weight: .semibold), nativeLabel(detail, secondary: true)], spacing: 8)
        add(content)
    }
    func add(_ content: NSView) {
        stack.addArrangedSubview(content); content.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    func group(_ title: String, rows: [(String, NSView)], note: String? = nil) {
        let body = column(spacing: 10)
        body.addArrangedSubview(nativeLabel(title, size: 13, weight: .semibold))
        let box = NSBox(); box.boxType = .custom; box.borderWidth = 0
        box.fillColor = .controlBackgroundColor; box.cornerRadius = MacUI.cornerRadius; box.contentViewMargins = .zero
        let fields = column(spacing: 12)
        for (index, pair) in rows.enumerated() {
            if index > 0 {
                let separator = NSBox(); separator.boxType = .separator
                fields.addArrangedSubview(separator); separator.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true
            }
            let label = nativeLabel(pair.0); label.widthAnchor.constraint(equalToConstant: 132).isActive = true
            pair.1.setAccessibilityLabel(pair.0)
            let field = row([label, pair.1]); fields.addArrangedSubview(field)
            field.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true
            pair.1.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        pin(fields, in: box.contentView!, inset: 16)
        body.addArrangedSubview(box); box.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        if let note { let label = nativeLabel(note, size: 11, secondary: true); body.addArrangedSubview(label); label.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true }
        add(body)
    }
    func choice(_ key: String, choices: [(String, String)]) -> ChoiceControl {
        let control = ChoiceControl(choices) { [weak self] value in self?.send("configure", ["patch": [key: value]]) }
        controls[key] = control; return control
    }
    func detail(_ key: String, text: String = "") -> NSTextField {
        let label = nativeLabel(text, secondary: true); label.isSelectable = true; details[key] = label; return label
    }
    func update(_ value: [String: Any]) {
        state = value
        for (key, control) in controls {
            if let choice = control as? ChoiceControl { choice.selectValue(settings[key] as? String ?? "") }
        }
    }
}
