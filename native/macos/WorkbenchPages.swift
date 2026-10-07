import AppKit

let workModes = [("realtime", "千问实时音频翻译"), ("text", "本地识别 + 文本翻译"), ("offline", "离线原文字幕")]
let displayModes = [("bilingual", "原文与译文"), ("original", "仅原文"), ("translation", "仅译文")]
let languages = [("zh", "中文"), ("en", "英语"), ("ja", "日语"), ("ko", "韩语"), ("fr", "法语"), ("de", "德语"), ("es", "西班牙语")]

final class LivePage: FormPage {
    let transcript = TranscriptView()
    private var deviceSignature = ""
    private var device: ChoiceControl!
    override func loadView() {
        view = NSView()
        let mode = choice("mode", choices: workModes)
        let source = choice("source", choices: [("system", "系统声音"), ("microphone", "麦克风")])
        source.changed = { [weak self] value in self?.send("configure", ["patch": ["source": value, "deviceId": ""]]) }
        device = choice("deviceId", choices: [("", "默认设备")])
        let sourceRow = row([nativeLabel("声音来源", secondary: true), source, device, spacer()])
        let settingsButton = ActionButton("配置", symbol: "slider.horizontal.3") { [weak self] in self?.send("navigate", ["page": 2]) }
        let modeRow = row([nativeLabel("工作模式", secondary: true), mode, spacer(), settingsButton])
        let inputs = column([sourceRow, modeRow], spacing: 10)
        sourceRow.widthAnchor.constraint(equalTo: inputs.widthAnchor).isActive = true
        modeRow.widthAnchor.constraint(equalTo: inputs.widthAnchor).isActive = true
        source.setAccessibilityLabel("声音来源"); device.setAccessibilityLabel("输入设备"); mode.setAccessibilityLabel("工作模式")
        let title = nativeLabel("实时字幕", size: MacUI.headingSize, weight: .semibold)
        let body = column([title, inputs, transcript], spacing: 20)
        pin(body, in: view, inset: 24)
        for item in [title, inputs, transcript] { item.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true }
        transcript.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        transcript.setContentHuggingPriority(.defaultLow, for: .vertical)
    }
    override func update(_ value: [String: Any]) {
        super.update(value)
        let source = settings["source"] as? String ?? "system"
        let devices = (value["devices"] as? [[String: Any]] ?? []).filter { $0["source"] as? String == source }
        let names = devices.map { ($0["id"] as? String ?? "", $0["name"] as? String ?? "设备") }
        let signature = source + names.map { $0.0 + $0.1 }.joined()
        if signature != deviceSignature {
            deviceSignature = signature; device.removeAllItems()
            device.values = [""] + names.map { $0.0 }; device.addItems(withTitles: ["默认设备"] + names.map { $0.1 })
        }
        device.selectValue(settings["deviceId"] as? String ?? "")
        let locked = value["running"] as? Bool == true || value["busy"] as? Bool == true
        for control in controls.values { control.isEnabled = !locked }
        let generation = value["generation"] as? Int ?? 0
        let segments = (value["segments"] as? [[String: Any]] ?? []).filter { $0["generation"] as? Int == generation }
        transcript.update(segments, display: settings["display"] as? String ?? "bilingual", autoscroll: true)
    }
}

final class ModelsPage: FormPage {
    private var catalogSignature = ""
    private var entries: [String: (NSTextField, ActionButton, ActionButton)] = [:]
    private let progress = NSProgressIndicator()
    private var pause: ActionButton!, cancel: ActionButton!
    private let modelRows = column(spacing: 12)
    override func loadView() {
        super.loadView()
        heading("本地模型", detail: "为离线识别选择合适的模型。首次使用可下载，也可导入已有 GGML 模型。")
        add(row([
            ActionButton("导入模型…", symbol: "square.and.arrow.down") { [weak self] in self?.send("importModel", [:]) },
            ActionButton("在 Finder 中显示", symbol: "folder") { [weak self] in self?.send("openModels", [:]) }, spacer(),
            ActionButton("更改位置…") { [weak self] in self?.send("changeModelDirectory", [:]) },
        ]))
        add(detail("directory"))
        add(modelRows)
        progress.style = .bar; progress.isIndeterminate = false; progress.maxValue = 1
        pause = ActionButton("暂停下载") { [weak self] in self?.send("pauseDownload", [:]) }
        cancel = ActionButton("取消下载") { [weak self] in self?.send("cancelDownload", [:]) }
        group("下载状态", rows: [("进度", progress), ("状态", detail("download")), ("操作", row([pause, cancel, spacer()]))])
        add(nativeLabel("模型下载后会校验完整性。本地识别运行在你的 Mac 上，不需要 API Key。", size: 11, secondary: true))
    }
    override func update(_ value: [String: Any]) {
        super.update(value)
        let models = value["models"] as? [[String: Any]] ?? []
        let signature = models.map { $0["id"] as? String ?? "" }.joined()
        if signature != catalogSignature {
            catalogSignature = signature
            for view in modelRows.arrangedSubviews { modelRows.removeArrangedSubview(view); view.removeFromSuperview() }; entries.removeAll()
            for model in models {
                let id = model["id"] as? String ?? "", name = model["name"] as? String ?? id
                let description = nativeLabel("", size: 11, secondary: true)
                let text = column([nativeLabel(name, size: 15, weight: .semibold), description], spacing: 6)
                let use = ActionButton("下载") { [weak self] in
                    guard let self else { return }
                    let installed = (self.state["models"] as? [[String: Any]] ?? []).first { $0["id"] as? String == id }?["installed"] as? Bool == true
                    self.send(installed ? "loadModel" : "downloadModel", ["id": id])
                }
                let remove = ActionButton("删除", symbol: "trash") { [weak self] in
                    guard let self, let window = self.view.window else { return }
                    let alert = NSAlert(); alert.messageText = "删除 \(name)？"; alert.informativeText = "将删除下载的模型文件。需要时可以重新下载。"
                    alert.addButton(withTitle: "删除模型"); alert.addButton(withTitle: "取消")
                    alert.beginSheetModal(for: window) { response in if response == .alertFirstButtonReturn { self.send("removeModel", ["id": id]) } }
                }
                let content = row([nativeSymbol("cpu", size: 24), text, spacer(), use, remove])
                let box = NSBox(); box.boxType = .custom; box.borderWidth = 0; box.fillColor = .controlBackgroundColor; box.cornerRadius = MacUI.cornerRadius; box.contentViewMargins = .zero
                pin(content, in: box.contentView!, inset: 16)
                modelRows.addArrangedSubview(box); box.widthAnchor.constraint(equalTo: modelRows.widthAnchor).isActive = true
                entries[id] = (description, use, remove)
            }
        }
        let download = value["download"] as? [String: Any] ?? [:]
        let downloading = download["running"] as? Bool == true || download["verifying"] as? Bool == true
        let locked = value["running"] as? Bool == true || value["busy"] as? Bool == true || value["loadingModel"] as? Bool == true
        for model in models {
            guard let entry = entries[model["id"] as? String ?? ""] else { continue }
            let installed = model["installed"] as? Bool == true, selected = model["selected"] as? Bool == true
            entry.0.stringValue = "\(ByteCountFormatter.string(fromByteCount: (model["bytes"] as? NSNumber)?.int64Value ?? 0, countStyle: .file)) · 内存约 \(model["memoryMB"] as? Int ?? 0) MB · \(selected ? "使用中" : installed ? "已下载" : "尚未下载")"
            entry.1.title = selected ? "已选用" : installed ? "使用模型" : download["paused"] as? Bool == true && download["activeId"] as? String == model["id"] as? String ? "继续下载" : "下载"
            entry.1.setAccessibilityLabel(entry.1.title + " " + (model["name"] as? String ?? ""))
            entry.1.isEnabled = !locked && !downloading && !selected
            entry.2.isHidden = !installed; entry.2.isEnabled = !locked && !downloading
        }
        let total = (download["total"] as? NSNumber)?.doubleValue ?? 0, received = (download["received"] as? NSNumber)?.doubleValue ?? 0
        progress.doubleValue = total > 0 ? received / total : 0
        details["directory"]?.stringValue = value["modelDirectory"] as? String ?? ""
        let receivedText = ByteCountFormatter.string(fromByteCount: Int64(received), countStyle: .file)
        details["download"]?.stringValue = download["error"] as? String ?? (download["verifying"] as? Bool == true ? "正在校验模型…" : downloading ? "已接收 \(receivedText) · \(Int((download["speed"] as? Double ?? 0) / 1024)) KB/s" : download["paused"] as? Bool == true ? "下载已暂停，可继续" : "没有进行中的下载")
        pause.isEnabled = download["running"] as? Bool == true; cancel.isEnabled = downloading || download["paused"] as? Bool == true
    }
}

final class ProvidersPage: FormPage, NSTextFieldDelegate {
    private var fields: [String: NSTextField] = [:]
    private var draftChoices: [String: ChoiceControl] = [:]
    private var cloud: ToggleControl!
    private var realtimeGroups: [NSView] = [], textGroups: [NSView] = []
    private var dirty = false
    private var saveButton: ActionButton!, testButton: ActionButton!
    private var initializedFields = false
    private var connectionGroup: NSView!, actionsGroup: NSView!, costNote: NSView!, offlineInfo: NSView!
    private var currentMode = ""
    private var saving = false
    private func field(_ key: String, placeholder: String = "", secret: Bool = false) -> NSTextField {
        let field: NSTextField = secret ? NSSecureTextField() : NSTextField()
        field.placeholderString = placeholder; field.delegate = self; fields[key] = field
        field.lineBreakMode = .byTruncatingTail; field.cell?.isScrollable = true
        return field
    }
    private func draft(_ key: String, choices: [(String, String)]) -> ChoiceControl {
        let choice = ChoiceControl(choices) { [weak self] _ in self?.dirty = true }; draftChoices[key] = choice; return choice
    }
    override func loadView() {
        super.loadView()
        heading("翻译服务", detail: "选择声音直接翻译，或在本地识别后仅发送文字。凭据由 macOS 钥匙串保存。")
        group("工作方式", rows: [("工作模式", choice("mode", choices: workModes))])
        let region = draft("region", choices: [("cn-beijing", "北京"), ("ap-southeast-1", "新加坡")])
        group("千问实时音频翻译", rows: [
            ("地域", region), ("Workspace ID", field("workspace", placeholder: "填写阿里云工作空间 ID")),
            ("服务地址", field("endpoint", placeholder: "留空使用地域默认 WebSocket 地址")),
            ("模型", field("modelId")),
        ], note: "此模式会通过加密连接持续发送声音片段。API Key 与地域、工作空间需匹配。")
        realtimeGroups.append(stack.arrangedSubviews.last!)
        let provider = draft("textProvider", choices: [("qwen", "千问"), ("openai", "OpenAI 兼容服务")])
        provider.changed = { [weak self] value in
            guard let self else { return }; self.dirty = true
            let base = self.fields["textBaseUrl"]!, model = self.fields["textModel"]!
            if ["https://dashscope.aliyuncs.com/compatible-mode/v1", "https://api.openai.com/v1"].contains(base.stringValue) {
                base.stringValue = value == "qwen" ? "https://dashscope.aliyuncs.com/compatible-mode/v1" : "https://api.openai.com/v1"
            }
            if ["qwen-mt-flash", "gpt-4.1-mini"].contains(model.stringValue) { model.stringValue = value == "qwen" ? "qwen-mt-flash" : "gpt-4.1-mini" }
        }
        group("文字翻译", rows: [("服务商", provider), ("API 地址", field("textBaseUrl")), ("模型", field("textModel"))], note: "声音留在本地，仅发送已确认的识别文本。此模式需要先准备本地模型。")
        textGroups.append(stack.arrangedSubviews.last!)
        cloud = ToggleControl("云端转写原文") { [weak self] _ in self?.dirty = true }
        group("语言与连接", rows: [
            ("源语言", draft("sourceLanguage", choices: [("auto", "自动识别")] + languages)),
            ("目标语言", draft("targetLanguage", choices: languages)),
            ("HTTP 代理", field("proxy", placeholder: "可选，例如 http://127.0.0.1:7890")),
            ("云端转写原文", cloud), ("API Key", field("key", placeholder: "留空保留现有凭据", secret: true)),
        ], note: "API Key 不会显示在界面状态、配置文件或诊断日志中。")
        connectionGroup = stack.arrangedSubviews.last!
        saveButton = ActionButton("保存配置", symbol: "checkmark") { [weak self] in self?.save(test: false) }
        saveButton.bezelColor = .controlAccentColor
        testButton = ActionButton("保存并测试连接", symbol: "network") { [weak self] in self?.save(test: true) }
        add(row([detail("saved", text: ""), spacer(), testButton, saveButton]))
        actionsGroup = stack.arrangedSubviews.last!
        add(nativeLabel("连接测试会访问选定服务，可能产生 API 费用。", size: 11, secondary: true))
        costNote = stack.arrangedSubviews.last!
        offlineInfo = column([
            nativeLabel("离线模式无需配置翻译服务", size: 17, weight: .semibold),
            nativeLabel("声音和识别文本都留在本机。准备一个本地模型，就可以开始生成原文字幕。", secondary: true),
            ActionButton("前往模型管理", symbol: "cpu") { [weak self] in self?.send("navigate", ["page": 1]) },
        ], spacing: 12)
        add(offlineInfo)
    }
    func controlTextDidChange(_ obj: Notification) { dirty = true; details["saved"]?.stringValue = "有未保存的修改" }
    private func save(test: Bool) {
        guard !saving else { return }; saving = true
        var patch: [String: Any] = [:]
        for (key, field) in fields where key != "key" { patch[key] = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
        for (key, choice) in draftChoices { patch[key] = choice.values[choice.indexOfSelectedItem] }
        patch["cloudTranscription"] = cloud.state == .on
        saveButton.isEnabled = false; testButton.isEnabled = false
        request("saveProvider", ["patch": patch, "key": fields["key"]?.stringValue ?? ""]) { [weak self] ok in
            guard let self else { return }
            if ok {
                self.dirty = false; self.fields["key"]?.stringValue = ""; self.details["saved"]?.stringValue = "配置已保存"
                if test {
                    self.request("testConnection", [:]) { [weak self] _ in self?.finishSaving() }
                    return
                }
            }
            self.finishSaving()
        }
    }
    private func finishSaving() { saving = false; update(state) }
    override func update(_ value: [String: Any]) {
        super.update(value)
        if !initializedFields || !dirty {
            initializedFields = true
            for (key, field) in fields where key != "key" { field.stringValue = settings[key] as? String ?? "" }
            for (key, choice) in draftChoices { choice.selectValue(settings[key] as? String ?? "") }
            cloud.state = settings["cloudTranscription"] as? Bool == true ? .on : .off
        }
        let mode = settings["mode"] as? String ?? "realtime"
        if !currentMode.isEmpty && currentMode != mode { fields["key"]?.stringValue = "" }
        currentMode = mode
        realtimeGroups.forEach { $0.isHidden = mode != "realtime" }; textGroups.forEach { $0.isHidden = mode != "text" }
        connectionGroup.isHidden = mode == "offline"; actionsGroup.isHidden = mode == "offline"
        costNote.isHidden = mode == "offline"; offlineInfo.isHidden = mode != "offline"
        cloud.isEnabled = mode == "realtime"
        let locked = value["running"] as? Bool == true || value["busy"] as? Bool == true
        for control in Array(fields.values) as [NSControl] { control.isEnabled = !locked }
        for control in draftChoices.values { control.isEnabled = !locked }
        controls["mode"]?.isEnabled = !locked; cloud.isEnabled = !locked && mode == "realtime"
        saveButton.isEnabled = !locked && !saving; testButton.isEnabled = !locked && !saving && mode != "offline"
    }
}

final class AppearancePage: FormPage {
    private let preview = LiquidGlassSurface(frame: .zero)
    private let original = nativeLabel("A little more understanding, in every moment.", size: 20, secondary: true)
    private let translation = nativeLabel("让每一个瞬间，多一份理解。", size: 28, weight: .semibold)
    private var font: ValueSlider!, opacity: ValueSlider!, through: ToggleControl!
    private var overlayButton: ActionButton!
    override func loadView() {
        super.loadView()
        heading("字幕外观", detail: "调整阅读舒适度，让悬浮字幕融入你的桌面。")
        let content = column([nativeLabel("悬浮字幕预览", size: 11, secondary: true), original, translation], spacing: 12)
        pin(content, in: preview.content, inset: 24); add(preview)
        font = ValueSlider("字幕字号", min: 14, max: 72) { [weak self] value in self?.send("configure", ["patch": ["fontSize": value.rounded()]]) }
        opacity = ValueSlider("背景不透明度", min: 0.1, max: 1) { [weak self] value in self?.send("configure", ["patch": ["opacity": value]]) }
        details["font"] = nativeLabel("28 pt", secondary: true)
        details["opacity"] = nativeLabel("80%", secondary: true)
        details["font"]?.widthAnchor.constraint(equalToConstant: 48).isActive = true
        details["opacity"]?.widthAnchor.constraint(equalToConstant: 48).isActive = true
        group("阅读", rows: [
            ("显示内容", choice("display", choices: displayModes)),
            ("字幕字号", row([font, details["font"]!])),
            ("背景不透明度", row([opacity, details["opacity"]!])),
            ("应用外观", choice("theme", choices: [("system", "跟随系统"), ("light", "浅色"), ("dark", "深色")])),
        ])
        through = ToggleControl("鼠标穿透") { [weak self] value in self?.send("clickThrough", ["value": value]) }
        overlayButton = ActionButton("打开悬浮字幕", symbol: "pip") { [weak self] in self?.send("toggleOverlay", [:]) }
        group("悬浮窗口", rows: [("鼠标穿透", through), ("窗口操作", row([
            overlayButton, ActionButton("恢复交互", symbol: "hand.point.up.left") { [weak self] in self?.send("recoverOverlay", [:]) }, spacer(),
        ]))], note: "拖动字幕窗口可以移动位置，右下角调整大小。鼠标穿透时，用菜单栏或 ⌃⌥⌘L 恢复交互。")
        add(nativeLabel("系统开启“减少透明度”后，玻璃背景会自动改为不透明材质。", size: 11, secondary: true))
    }
    override func update(_ value: [String: Any]) {
        super.update(value)
        let size = (settings["fontSize"] as? NSNumber)?.doubleValue ?? 28, alpha = (settings["opacity"] as? NSNumber)?.doubleValue ?? 0.8
        if !font.tracking { font.doubleValue = size }; if !opacity.tracking { opacity.doubleValue = alpha }
        details["font"]?.stringValue = "\(Int(size)) pt"; details["opacity"]?.stringValue = "\(Int(alpha * 100))%"
        original.font = .systemFont(ofSize: size * 0.8); translation.font = .systemFont(ofSize: size, weight: .semibold)
        let display = settings["display"] as? String ?? "bilingual"
        original.isHidden = display == "translation"; translation.isHidden = display == "original"
        preview.materialOpacity = alpha
        through.state = value["clickThrough"] as? Bool == true ? .on : .off
        overlayButton.title = value["overlayVisible"] as? Bool == true ? "隐藏悬浮字幕" : "打开悬浮字幕"; overlayButton.setAccessibilityLabel(overlayButton.title)
    }
}

final class HistoryPage: FormPage, NSSearchFieldDelegate {
    let transcript = TranscriptView(history: true)
    private var sessions: ChoiceControl!, display: ChoiceControl!, exportButton: ChoiceControl!
    private var persist: ToggleControl!, clear: ActionButton!
    private let search = NSSearchField()
    private var sessionSignature = ""
    private var selectedSession = "all", selectedDisplay = "bilingual"
    override func loadView() {
        view = NSView()
        sessions = ChoiceControl([("all", "全部会话")]) { [weak self] value in self?.selectedSession = value; self?.refreshText() }
        display = ChoiceControl(displayModes) { [weak self] value in self?.selectedDisplay = value; self?.refreshText() }
        search.placeholderString = "搜索字幕"; search.delegate = self; search.setAccessibilityLabel("搜索字幕")
        search.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        sessions.setAccessibilityLabel("选择会话"); display.setAccessibilityLabel("导出内容")
        exportButton = ChoiceControl([("", "导出…"), ("txt", "纯文本 TXT"), ("srt", "字幕 SRT"), ("vtt", "字幕 VTT")]) { [weak self] format in
            guard let self, !format.isEmpty else { return }
            var args: [String: Any] = ["format": format, "display": self.selectedDisplay]
            if let session = Int(self.selectedSession) { args["session"] = session }
            self.send("export", args); self.exportButton.selectItem(at: 0)
        }
        exportButton.setAccessibilityLabel("导出字幕")
        let filter = row([sessions, display, spacer(), search, exportButton])
        persist = ToggleControl("保存字幕历史到本机") { [weak self] value in self?.send("persistHistory", ["value": value]) }
        clear = ActionButton("清空历史…", symbol: "trash") { [weak self] in
            guard let self, let window = self.view.window else { return }
            let alert = NSAlert(); alert.messageText = "清空所有字幕历史？"; alert.informativeText = "本次操作会移除当前字幕和已保存的历史，无法撤销。已导出的文件不受影响。"
            alert.alertStyle = .warning; alert.addButton(withTitle: "清空历史"); alert.addButton(withTitle: "取消")
            alert.beginSheetModal(for: window) { response in if response == .alertFirstButtonReturn { self.send("clearHistory", [:]) } }
        }
        let footer = row([persist, nativeLabel("保存字幕历史到本机", size: 12), spacer(), clear])
        let note = nativeLabel("仅导出已确认字幕。SRT / VTT 需要单个会话及有效时间；搜索只筛选阅读区。", size: 11, secondary: true)
        let title = nativeLabel("历史与导出", size: MacUI.headingSize, weight: .semibold)
        let body = column([title, filter, transcript, footer, note], spacing: 12); pin(body, in: view, inset: 24)
        for item in [title, filter, transcript, footer, note] { item.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true }
        transcript.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        transcript.setContentHuggingPriority(.defaultLow, for: .vertical)
    }
    func controlTextDidChange(_ obj: Notification) { refreshText() }
    override func update(_ value: [String: Any]) {
        super.update(value)
        let segments = value["segments"] as? [[String: Any]] ?? []
        let ids = Set(segments.compactMap { $0["generation"] as? Int }).sorted(by: >)
        let signature = ids.map(String.init).joined(separator: ",")
        if signature != sessionSignature {
            sessionSignature = signature; sessions.removeAllItems(); sessions.values = ["all"] + ids.map(String.init)
            sessions.addItems(withTitles: ["全部会话"] + ids.map { "会话 \($0)" })
            if !sessions.values.contains(selectedSession) { selectedSession = "all" }; sessions.selectValue(selectedSession)
        }
        persist.state = settings["persistHistory"] as? Bool == true ? .on : .off
        clear.isEnabled = !segments.isEmpty && value["running"] as? Bool != true && value["busy"] as? Bool != true
        refreshText()
    }
    private func refreshText() {
        let segments = (state["segments"] as? [[String: Any]] ?? []).filter { selectedSession == "all" || String($0["generation"] as? Int ?? 0) == selectedSession }
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript.update(segments.filter { query.isEmpty || (($0["original"] as? String ?? "") + ($0["translation"] as? String ?? "")).localizedCaseInsensitiveContains(query) }, display: selectedDisplay)
        let finals = segments.filter { $0["final"] as? Bool == true }
        let timed = finals.contains { $0["startUs"] as? Int != nil && $0["endUs"] as? Int != nil }
        let single = Set(finals.compactMap { $0["generation"] as? Int }).count == 1
        exportButton.menu?.autoenablesItems = false
        exportButton.item(at: 1)?.isEnabled = !finals.isEmpty
        exportButton.item(at: 2)?.isEnabled = timed && single; exportButton.item(at: 3)?.isEnabled = timed && single
    }
}

final class SettingsPage: FormPage {
    private let diagnostics = NSTextView()
    private var fileButton: ActionButton!
    override func loadView() {
        super.loadView()
        heading("设置与诊断", detail: "查看声音权限、验证本地识别，并了解当前运行状态。")
        group("声音权限", rows: [("系统声音", detail("system")), ("麦克风", detail("microphone")), ("正在运行的应用", detail("appPath", text: Bundle.main.bundleURL.path)), ("操作", row([
            ActionButton("刷新状态", symbol: "arrow.clockwise") { [weak self] in self?.send("refresh", [:]) },
            ActionButton("打开隐私设置…", symbol: "gearshape") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
            }, spacer(),
        ]))], note: "只有开始字幕时才会采集声音。授权对应当前应用副本；开发测试包更新后可能需要重新添加授权。更改权限后，请完全退出并重新打开应用。")
        fileButton = ActionButton("选择 WAV 文件…", symbol: "doc.badge.waveform") { [weak self] in self?.send("processFile", [:]) }
        group("本地识别验证", rows: [("当前模型", detail("model")), ("音频文件", fileButton)], note: "WAV 文件在本地静默处理，不会播放。验证前需准备本地模型；离线模式不会访问翻译服务。")
        group("运行状态", rows: [("状态", detail("status")), ("处理速度", detail("rtf")), ("最终段耗时", detail("latency")), ("丢弃音频帧", detail("drops"))])
        add(nativeLabel("诊断记录", size: 13, weight: .semibold))
        diagnostics.isEditable = false; diagnostics.isSelectable = true; diagnostics.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        diagnostics.textColor = .secondaryLabelColor; diagnostics.drawsBackground = false; diagnostics.textContainerInset = NSSize(width: 8, height: 8)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = diagnostics; scroll.drawsBackground = false
        scroll.heightAnchor.constraint(equalToConstant: 170).isActive = true; add(scroll)
        add(nativeLabel("LumaCaption 0.1.0 · macOS 原生界面", size: 11, secondary: true))
    }
    override func update(_ value: [String: Any]) {
        super.update(value)
        let permissions = value["permissions"] as? [String: Any] ?? [:]
        let labels = ["authorized": "已允许", "granted": "已允许", "notGranted": "尚未允许", "notVerified": "开始采集时确认", "restartRequired": "授权已开启 · 请重启应用", "notAuthorized": "当前副本未获授权", "denied": "已拒绝", "restricted": "受系统限制", "notDetermined": "尚未请求"]
        for key in ["system", "microphone"] { let raw = permissions[key] as? String ?? "未知"; details[key]?.stringValue = labels[raw] ?? raw }
        details["model"]?.stringValue = value["selectedModel"] as? String ?? ""
        details["status"]?.stringValue = value["status"] as? String ?? ""
        details["rtf"]?.stringValue = String(format: "RTF %.2f（小于 1 表示快于实时）", value["rtf"] as? Double ?? 0)
        details["latency"]?.stringValue = (value["latencyMs"] as? Int).map { "\($0) ms" } ?? "尚无结果"
        details["drops"]?.stringValue = String(value["droppedFrames"] as? Int ?? 0)
        let records = (value["diagnostics"] as? [String] ?? []).joined(separator: "\n")
        if diagnostics.string != records { diagnostics.string = records.isEmpty ? "暂无诊断记录" : records }
        fileButton.isEnabled = value["running"] as? Bool != true && value["busy"] as? Bool != true && value["loadingModel"] as? Bool != true
    }
}
