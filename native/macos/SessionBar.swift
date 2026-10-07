import AppKit

/// The session controls stay available when navigating away from the transcript.
final class SessionBar: NSView {
    let glass = LiquidGlassSurface(frame: .zero)
    var send: (String) -> Void = { _ in }
    private let statusLabel = nativeLabel("正在初始化", size: 12, weight: .medium)
    private let privacy = nativeLabel("", size: 11, secondary: true)
    private let metrics = nativeLabel("", size: 11, secondary: true)
    private let meter = NSLevelIndicator()
    private var start: ActionButton!, pause: ActionButton!, overlay: ActionButton!, emergency: ActionButton!

    override init(frame: NSRect) {
        super.init(frame: frame)
        start = ActionButton("开始字幕", symbol: "play.fill") { [weak self] in self?.send("toggleStart") }
        start.bezelColor = .controlAccentColor
        pause = ActionButton("暂停", symbol: "pause.fill") { [weak self] in self?.send("pause") }
        overlay = ActionButton("打开悬浮字幕", symbol: "pip") { [weak self] in self?.send("toggleOverlay") }
        emergency = ActionButton("立即停止", symbol: "stop.circle") { [weak self] in self?.send("emergency") }
        emergency.toolTip = "立即停止采集并丢弃待处理音频"
        meter.levelIndicatorStyle = .continuousCapacity; meter.minValue = 0; meter.maxValue = 1
        meter.setAccessibilityLabel("输入音量"); meter.widthAnchor.constraint(equalToConstant: 64).isActive = true
        statusLabel.maximumNumberOfLines = 1; statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 190).isActive = true
        let actions = row([nativeSymbol("waveform", size: 16), statusLabel, meter, spacer(), overlay, pause, start], spacing: 10)
        let detail = row([nativeSymbol("lock.shield", size: 13), privacy, spacer(), metrics, emergency], spacing: 8)
        privacy.maximumNumberOfLines = 2; metrics.maximumNumberOfLines = 1
        metrics.lineBreakMode = .byTruncatingTail
        let body = column([actions, detail], spacing: 10)
        pin(body, in: glass.content, inset: 14)
        actions.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        detail.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        pin(glass, in: self)
        setAccessibilityLabel("字幕会话控制栏")
        update([:])
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ value: [String: Any]) {
        let running = value["running"] as? Bool == true
        let busy = value["busy"] as? Bool == true || value["loadingModel"] as? Bool == true || value["initialized"] as? Bool != true
        let paused = value["paused"] as? Bool == true
        start.title = running ? "停止字幕" : "开始字幕"
        start.image = NSImage(systemSymbolName: running ? "stop.fill" : "play.fill", accessibilityDescription: nil)?.withSymbolConfiguration(.init(paletteColors: [MacUI.textColor(on: .controlAccentColor)]))
        start.isEnabled = !busy
        pause.title = paused ? "继续" : "暂停"
        pause.image = NSImage(systemSymbolName: paused ? "play.pause" : "pause.fill", accessibilityDescription: nil)
        pause.isEnabled = running && !busy
        overlay.title = value["overlayVisible"] as? Bool == true ? "隐藏悬浮字幕" : "打开悬浮字幕"
        emergency.isEnabled = running && !busy
        for button in [start, pause, overlay, emergency] { button?.setAccessibilityLabel(button?.title); button?.needsDisplay = true }
        statusLabel.stringValue = value["status"] as? String ?? "正在初始化"
        privacy.stringValue = value["privacy"] as? String ?? ""
        meter.doubleValue = min(1, (value["level"] as? Double ?? 0) * 6)
        let rtf = value["rtf"] as? Double ?? 0, model = value["selectedModel"] as? String ?? "尚未选择"
        metrics.stringValue = rtf > 0 ? String(format: "RTF %.2f · %@", rtf, model) : "模型：\(model)"
    }
}

final class SidebarRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        NSColor.labelColor.withAlphaComponent(isEmphasized ? 0.10 : 0.07).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 2), xRadius: MacUI.cornerRadius, yRadius: MacUI.cornerRadius).fill()
    }
}
