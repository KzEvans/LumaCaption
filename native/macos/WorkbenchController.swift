import AppKit
import FlutterMacOS

/// Every visible macOS view belongs to AppKit. The Flutter engine is a backend host.
final class WorkbenchController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSToolbarDelegate, NSMenuItemValidation, NSToolbarItemValidation {
    let root = NSSplitViewController()
    let pages: [FormPage] = [LivePage(), ModelsPage(), ProvidersPage(), AppearancePage(), HistoryPage(), SettingsPage()]
    let titles = ["实时字幕", "模型管理", "翻译服务", "字幕外观", "历史与导出", "设置与诊断"]
    private let symbols = ["captions.bubble", "cpu", "character.bubble", "textformat", "clock.arrow.circlepath", "slider.horizontal.3"]
    private let channel: FlutterMethodChannel
    private let table = NSTableView()
    private let content = NSViewController()
    private let pageHost = NSView()
    private let errorLabel = nativeLabel("", size: 12)
    private var errorBanner: NSStackView!
    private var state: [String: Any] = [:]
    private var toolbarItems: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private(set) var selectedPage = 0
    weak var window: NSWindow?
    private var sidebarItem: NSSplitViewItem!
    private let startID = NSToolbarItem.Identifier("Luma.start")
    private let pauseID = NSToolbarItem.Identifier("Luma.pause")
    private let overlayID = NSToolbarItem.Identifier("Luma.overlay")

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "lumacaption/design", binaryMessenger: messenger)
        super.init()
        build()
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self else { result(nil); return }
            switch call.method {
            case "sync": self.update(call.arguments as? [String: Any] ?? [:]); result(nil)
            case "status": result(self.status())
            default: result(FlutterMethodNotImplemented)
            }
        }
    }
    private func build() {
        root.splitView.autosaveName = "LumaCaption.sidebar"; root.splitView.dividerStyle = .thin
        let sidebar = NSViewController(); sidebar.view = NSView()
        let scroll = NSScrollView(); scroll.hasVerticalScroller = false; scroll.drawsBackground = false
        table.addTableColumn(NSTableColumn(identifier: .init("page")))
        table.headerView = nil; table.dataSource = self; table.delegate = self; table.style = .sourceList
        table.rowHeight = 40; table.intercellSpacing = NSSize(width: 0, height: 4)
        table.allowsEmptySelection = false
        table.setAccessibilityLabel("LumaCaption 侧边栏")
        scroll.documentView = table
        let brand = nativeLabel("LumaCaption", size: 16, weight: .semibold)
        let footer = nativeLabel("让理解，跟上声音。", size: 11, secondary: true)
        let sidebarStack = column([brand, scroll, footer], spacing: 18); pin(sidebarStack, in: sidebar.view, inset: 16)
        for view in [brand, scroll, footer] { view.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor).isActive = true }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 190; sidebarItem.maximumThickness = 270
        sidebarItem.allowsFullHeightLayout = true; sidebarItem.canCollapse = true
        sidebarItem.titlebarSeparatorStyle = .none; root.addSplitViewItem(sidebarItem)

        content.view = NSView()
        errorLabel.textColor = .systemRed
        errorBanner = row([nativeSymbol("exclamationmark.circle"), errorLabel, spacer(), ActionButton("关闭") { [weak self] in self?.send("clearError") }])
        errorBanner.edgeInsets = NSEdgeInsets(top: 12, left: 24, bottom: 4, right: 24)
        let stack = column([errorBanner, pageHost], spacing: 0); pin(stack, in: content.view)
        errorBanner.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        pageHost.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        pageHost.setContentHuggingPriority(.defaultLow, for: .vertical); errorBanner.isHidden = true
        let item = NSSplitViewItem(viewController: content); item.minimumThickness = 640; root.addSplitViewItem(item)
        for page in pages {
            page.send = { [weak self] action, args in self?.send(action, args) }
            page.request = { [weak self] action, args, completion in self?.send(action, args, completion: completion) }
            content.addChild(page); _ = page.view
        }
        table.reloadData(); table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        navigate(0)
    }
    func attach(to window: NSWindow) {
        self.window = window
        let toolbar = NSToolbar(identifier: "LumaCaption.toolbar"); toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel; toolbar.allowsUserCustomization = true; toolbar.autosavesConfiguration = true
        window.toolbar = toolbar; window.toolbarStyle = .unified
        window.titleVisibility = .visible
        window.titlebarSeparatorStyle = .none
        window.title = titles[selectedPage]; window.subtitle = "LumaCaption"
    }
    func send(_ action: String, _ args: [String: Any] = [:], completion: ((Bool) -> Void)? = nil) {
        if action == "navigate" { navigate(args["page"] as? Int ?? 0); completion?(true); return }
        var payload = args; payload["action"] = action
        channel.invokeMethod("action", arguments: payload) { value in completion?(!(value is FlutterError)) }
    }
    func navigate(_ page: Int) {
        guard pages.indices.contains(page) else { return }
        window?.makeFirstResponder(nil)
        selectedPage = page
        pageHost.subviews.forEach { $0.removeFromSuperview() }
        pin(pages[page].view, in: pageHost)
        pages[page].update(state)
        if table.selectedRow != page { table.selectRowIndexes(IndexSet(integer: page), byExtendingSelection: false) }
        window?.title = titles[page]
        window?.recalculateKeyViewLoop()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { titles.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        let cell = NSTableCellView()
        let image = nativeSymbol(symbols[index], size: 17); image.contentTintColor = .controlAccentColor
        let label = nativeLabel(titles[index]); label.maximumNumberOfLines = 1
        let contents = row([image, label], spacing: 10); pin(contents, in: cell, inset: 6)
        cell.textField = label; cell.imageView = image
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { if table.selectedRow >= 0 && table.selectedRow != selectedPage { navigate(table.selectedRow) } }
    private func update(_ value: [String: Any]) {
        let previous = (state["settings"] as? [String: Any])?["theme"] as? String
        state = value
        let theme = (value["settings"] as? [String: Any])?["theme"] as? String ?? "system"
        if previous != theme { window?.appearance = theme == "dark" ? NSAppearance(named: .darkAqua) : theme == "light" ? NSAppearance(named: .aqua) : nil }
        errorLabel.stringValue = value["error"] as? String ?? ""; errorBanner.isHidden = errorLabel.stringValue.isEmpty
        pages[selectedPage].update(value)
        let running = value["running"] as? Bool == true, paused = value["paused"] as? Bool == true
        let busy = value["busy"] as? Bool == true || value["loadingModel"] as? Bool == true || value["initialized"] as? Bool != true
        setToolbar(startID, title: running ? "停止字幕" : "开始字幕", symbol: running ? "stop.fill" : "play.fill", enabled: !busy)
        setToolbar(pauseID, title: paused ? "继续" : "暂停", symbol: paused ? "play.pause" : "pause", enabled: running && !busy)
        setToolbar(overlayID, title: value["overlayVisible"] as? Bool == true ? "隐藏悬浮字幕" : "打开悬浮字幕", symbol: "pip", enabled: true)
    }
    private func setToolbar(_ id: NSToolbarItem.Identifier, title: String, symbol: String, enabled: Bool) {
        toolbarItems[id]?.label = title; toolbarItems[id]?.paletteLabel = title; toolbarItems[id]?.toolTip = title
        toolbarItems[id]?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        toolbarItems[id]?.isEnabled = enabled
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, overlayID, pauseID, startID] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, overlayID, pauseID, startID] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == .toggleSidebar {
            let item = NSToolbarItem(itemIdentifier: id); item.label = "侧边栏"; item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "显示或隐藏侧边栏")
            item.target = root; item.action = #selector(NSSplitViewController.toggleSidebar(_:)); return item
        }
        if id == .sidebarTrackingSeparator { return NSTrackingSeparatorToolbarItem(identifier: id, splitView: root.splitView, dividerIndex: 0) }
        guard [overlayID, pauseID, startID].contains(id) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id); item.target = self; item.isBordered = true
        item.action = id == startID ? #selector(toggleStart) : id == pauseID ? #selector(pause) : #selector(toggleOverlay)
        item.label = id == startID ? "开始字幕" : id == pauseID ? "暂停" : "打开悬浮字幕"
        item.image = NSImage(systemSymbolName: id == startID ? "play.fill" : id == pauseID ? "pause" : "pip", accessibilityDescription: item.label)
        if #available(macOS 26.0, *), id == startID { item.style = .prominent }
        toolbarItems[id] = item; return item
    }
    @objc func toggleStart() { send("toggleStart") }
    @objc func pause() { send("pause") }
    @objc func toggleOverlay() { send("toggleOverlay") }
    @objc func stop() { send("stop") }
    @objc func emergency() { send("emergency") }
    @objc func goPage(_ sender: NSMenuItem) { window?.makeKeyAndOrderFront(nil); navigate(sender.tag) }
    @objc func settingsPage() { window?.makeKeyAndOrderFront(nil); navigate(5) }
    @objc func find() {
        let transcript = selectedPage == 4 ? (pages[4] as! HistoryPage).transcript : (pages[0] as! LivePage).transcript
        if selectedPage != 0 && selectedPage != 4 { navigate(4) }
        let target = selectedPage == 4 ? (pages[4] as! HistoryPage).transcript : transcript
        window?.makeFirstResponder(target.text)
        let item = NSMenuItem(); item.tag = NSTextFinder.Action.showFindInterface.rawValue
        target.text.performFindPanelAction(item)
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let running = state["running"] as? Bool == true, busy = state["busy"] as? Bool == true
        if menuItem.action == #selector(pause) || menuItem.action == #selector(stop) || menuItem.action == #selector(emergency) { return running && !busy }
        if menuItem.action == #selector(toggleStart) { return !busy && state["loadingModel"] as? Bool != true && state["initialized"] as? Bool == true }
        if menuItem.action == #selector(goPage(_:)) { menuItem.state = menuItem.tag == selectedPage ? .on : .off }
        return true
    }
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        let busy = state["busy"] as? Bool == true || state["loadingModel"] as? Bool == true
        if item.itemIdentifier == startID { return !busy && state["initialized"] as? Bool == true }
        if item.itemIdentifier == pauseID { return state["running"] as? Bool == true && !busy }
        return true
    }
    func status() -> [String: Any] {
        func controls(_ view: NSView) -> [String] {
            (view is NSControl || view is NSTextView ? [String(describing: type(of: view))] : []) + view.subviews.flatMap(controls)
        }
        return [
            "renderer": "AppKit", "page": selectedPage, "toolbar": "NSToolbar", "sidebar": "NSSplitViewController",
            "reduceTransparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "pages": pages.enumerated().map { ["title": titles[$0.offset], "controls": controls($0.element.view)] as [String: Any] },
            "liveMaterial": (pages[0] as! LivePage).glass.materialName,
            "width": root.view.bounds.width, "height": root.view.bounds.height,
        ]
    }
}
