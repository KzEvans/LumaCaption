import AppKit
import FlutterMacOS
import Security
import UniformTypeIdentifiers

@available(macOS 13.3, *)
final class NativeBridge: NSObject, FlutterStreamHandler {
    let audio = AudioCapture()
    let overlay = OverlayController()
    private var sink: FlutterEventSink?
    private let channel: FlutterMethodChannel
    private let events: FlutterEventChannel
    weak var mainWindow: NSWindow?
    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "lumacaption/native", binaryMessenger: messenger)
        events = FlutterEventChannel(name: "lumacaption/audio", binaryMessenger: messenger)
        super.init()
        events.setStreamHandler(self)
        audio.onEvent = { [weak self] data in
            var value = data
            if let pcm = data["pcm"] as? Data { value["pcm"] = FlutterStandardTypedData(bytes: pcm) }
            self?.sink?(value)
        }
        overlay.onCommand = { [weak self] command in self?.sink?(["type": "command", "command": command]) }
        channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result: result) }
    }
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? { sink = events; return nil }
    func onCancel(withArguments arguments: Any?) -> FlutterError? { sink = nil; return nil }
    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        var method = call.method
        if method.hasPrefix("audio.") { method = String(method.dropFirst(6)) }
        do {
            switch method {
            case "start":
                Task { @MainActor in
                    let source = args["source"] as? String ?? "system"
                    do { try await audio.start(source: source, deviceID: args["deviceId"] as? String); result(nil) }
                    catch {
                        let report = CaptureErrorReport(error, source: source)
                        result(FlutterError(code: report.code, message: report.message, details: report.details))
                    }
                }
            case "stop": audio.stop(); result(nil)
            case "pause": audio.pause(); result(nil)
            case "resume": audio.resume(); result(nil)
            case "devices": result(AudioCapture.devices())
            case "permissions": result(audio.permissions())
            case "status": result(["running": audio.running])
            case "overlay.show": overlay.show(); result(nil)
            case "overlay.hide": overlay.hide(); result(nil)
            case "overlay.update": overlay.update(original: args["original"] as? String ?? "", stableOriginal: args["stableOriginal"] as? String ?? "", translation: args["translation"] as? String ?? ""); result(nil)
            case "overlay.configure": overlay.configure(args); result(nil)
            case "overlay.status": result(overlay.status())
            case "overlay.recover": overlay.recoverInteraction(); result(nil)
            case "secrets.read", "secrets.write", "secrets.delete": result(try secret(method, args))
            case "paths":
                let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LumaCaption")
                try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
                result(["support": support.path, "documents": FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path])
            case "files.freeBytes":
                let path = args["path"] as? String ?? NSHomeDirectory()
                let attributes = try FileManager.default.attributesOfFileSystem(forPath: path)
                result(attributes[.systemFreeSize])
            case "files.pickModel", "files.pickAudio", "files.pickDirectory":
                let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
                panel.canChooseDirectories = method == "files.pickDirectory"; panel.canChooseFiles = !panel.canChooseDirectories
                if method == "files.pickModel" { panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data] }
                if method == "files.pickAudio" { panel.allowedContentTypes = [.wav] }
                let completion: (NSApplication.ModalResponse) -> Void = { response in result(response == .OK ? panel.url?.path : nil) }
                if let window = mainWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
                else { panel.begin(completionHandler: completion) }
            case "files.saveText":
                let panel = NSSavePanel(); panel.nameFieldStringValue = args["suggestedName"] as? String ?? "LumaCaption.txt"
                let completion: (NSApplication.ModalResponse) -> Void = { response in
                    guard response == .OK, let url = panel.url else { result(nil); return }
                    do { try (args["text"] as? String ?? "").write(to: url, atomically: true, encoding: .utf8); result(url.path) }
                    catch { result(FlutterError(code: "save", message: error.localizedDescription, details: nil)) }
                }
                if let window = mainWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
                else { panel.begin(completionHandler: completion) }
            case "openPath":
                guard let path = args["path"] as? String, FileManager.default.fileExists(atPath: path) else { throw NSError(domain: "LumaCaption", code: 1, userInfo: [NSLocalizedDescriptionKey: "文件或目录不存在"]) }
                NSWorkspace.shared.open(URL(fileURLWithPath: path)); result(nil)
            case "systemSpeech.status": result(["state": "unsupportedOS", "message": "Windows 系统语音识别仅用于 Windows；请使用 Whisper。"])
            default: result(FlutterMethodNotImplemented)
            }
        } catch { result(FlutterError(code: "native", message: error.localizedDescription, details: nil)) }
    }
    private func secret(_ method: String, _ args: [String: Any]) throws -> String? {
        guard let account = args["account"] as? String, !account.isEmpty else { throw NSError(domain: "Keychain", code: 1) }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.lumacaption.credentials", kSecAttrAccount as String: account]
        if method == "secrets.read" {
            var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?; let code = SecItemCopyMatching(q as CFDictionary, &item)
            if code == errSecItemNotFound { return nil }
            guard code == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(code)) }
            return (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
        }
        if method == "secrets.delete" { let code = SecItemDelete(query as CFDictionary); if code != errSecSuccess && code != errSecItemNotFound { throw NSError(domain: NSOSStatusErrorDomain, code: Int(code)) }; return nil }
        let data = Data((args["value"] as? String ?? "").utf8)
        var code = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if code == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            code = SecItemAdd(q as CFDictionary, nil)
        }
        guard code == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(code)) }; return nil
    }
    func shutdown() { audio.stop(); overlay.dispose(); channel.setMethodCallHandler(nil); events.setStreamHandler(nil); sink = nil }
}
