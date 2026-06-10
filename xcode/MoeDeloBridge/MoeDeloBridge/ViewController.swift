//
//  ViewController.swift
//  MoeDeloBridge
//

import Cocoa
import SafariServices
import WebKit

let extensionBundleIdentifier = "ru.edomost.safari.Extension"
let pluginCheckURL = "http://127.0.0.1:18080/TRUST/GetVer"

// MARK: - Фоновый режим плагина (служба без значка в Доке)
//
// «Включить» — три обратимых шага, без прав администратора и без правки файлов вендора:
//   1) теневой бандл в ~/Library/Application Support/…: копия Info.plist с
//      LSUIElement=true (фоновое приложение без значка в Доке), а MacOS/Resources —
//      симлинки на оригинал, так что бинарник, база и лог остаются вендорскими;
//   2) вендорский LaunchAgent (/Library/LaunchAgents/StekTrustPlugin.plist)
//      отключается per-user override'ом, чтобы при входе не поднималась
//      вторая копия со значком (у плагина нет защиты от двух копий);
//   3) наш агент ~/Library/LaunchAgents/ru.edomost.stektrust.plist запускает
//      теневой путь при входе в систему и перезапускает плагин при сбое.
// «Выключить» откатывает всё и запускает плагин как раньше (значок вернётся).

enum PluginService {
    static let pluginApp = "/Applications/StekTrustPlugin.app"
    static let pluginBinary = pluginApp + "/Contents/MacOS/StekTrustPlugin"
    static let vendorLabel = "StekTrustPlugin"
    static let label = "ru.edomost.stektrust"

    static var home: String { NSHomeDirectory() }
    static var shadow: String { home + "/Library/Application Support/ЭДО Мост для Safari/StekTrustShadow" }
    static var shadowBinary: String { shadow + "/Contents/MacOS/StekTrustPlugin" }
    static var agentPlist: String { home + "/Library/LaunchAgents/\(label).plist" }
    static var gui: String { "gui/\(getuid())" }

    static var pluginInstalled: Bool { FileManager.default.fileExists(atPath: pluginBinary) }

    static var enabled: Bool {
        FileManager.default.fileExists(atPath: agentPlist) && launchctl("print", "\(gui)/\(label)") == 0
    }

    /// Состояние для UI: "on" / "off" / "noplugin".
    static var state: String {
        if !pluginInstalled { return "noplugin" }
        return enabled ? "on" : "off"
    }

    static func enable() throws {
        let fm = FileManager.default
        guard pluginInstalled else {
            throw err("Плагин подписи не найден в /Applications/StekTrustPlugin.app")
        }

        // 1. Теневой бандл: патченный Info.plist + симлинки на всё остальное.
        try? fm.removeItem(atPath: shadow)
        try fm.createDirectory(atPath: shadow + "/Contents", withIntermediateDirectories: true)
        let infoData = try Data(contentsOf: URL(fileURLWithPath: pluginApp + "/Contents/Info.plist"))
        guard var info = try PropertyListSerialization.propertyList(from: infoData, format: nil)
                as? [String: Any] else {
            throw err("Не удалось прочитать Info.plist плагина")
        }
        info["LSUIElement"] = true
        let patched = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try patched.write(to: URL(fileURLWithPath: shadow + "/Contents/Info.plist"))
        for item in try fm.contentsOfDirectory(atPath: pluginApp + "/Contents") {
            // Подписи у вендора нет; если появится — битую печать не наследуем.
            if item == "Info.plist" || item == "_CodeSignature" { continue }
            try fm.createSymbolicLink(atPath: shadow + "/Contents/" + item,
                                      withDestinationPath: pluginApp + "/Contents/" + item)
        }

        // 2. Отключить вендорский автозапуск (он поднимал бы копию со значком).
        launchctl("bootout", "\(gui)/\(vendorLabel)")
        launchctl("disable", "\(gui)/\(vendorLabel)")

        // 3. Остановить запущенные вручную копии — порт 18080 должен освободиться.
        killPluginProcesses()

        // 4. Наш агент: автозапуск при входе + перезапуск при сбое,
        //    пока установлен сам плагин (PathState).
        let agent: [String: Any] = [
            "Label": label,
            "ProgramArguments": [shadowBinary],
            "RunAtLoad": true,
            "KeepAlive": ["PathState": [pluginBinary: true]],
            "ProcessType": "Interactive",
            "AssociatedBundleIdentifiers": ["ru.edomost.safari"],
        ]
        try fm.createDirectory(atPath: home + "/Library/LaunchAgents", withIntermediateDirectories: true)
        let agentData = try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0)
        try agentData.write(to: URL(fileURLWithPath: agentPlist))

        launchctl("bootout", "\(gui)/\(label)")   // вдруг остался от прошлого включения
        launchctl("enable", "\(gui)/\(label)")    // вдруг выключали в Системных настройках
        if launchctl("bootstrap", gui, agentPlist) != 0 {
            throw err("launchctl bootstrap не выполнился")
        }
    }

    static func disable() {
        launchctl("bootout", "\(gui)/\(label)")
        try? FileManager.default.removeItem(atPath: agentPlist)
        try? FileManager.default.removeItem(atPath: shadow)
        killPluginProcesses()
        launchctl("enable", "\(gui)/\(vendorLabel)")  // вернуть вендорский автозапуск
        if pluginInstalled {                          // и запустить как раньше — со значком
            run("/usr/bin/open", [pluginApp])         // блокирующий: переживает exit() CLI-пути
        }
    }

    /// Убивает все копии плагина (вендорный и теневой пути) и ждёт их завершения.
    static func killPluginProcesses() {
        run("/usr/bin/pkill", ["-f", "Contents/MacOS/StekTrustPlugin"])
        for _ in 0..<30 {  // до 3 секунд
            if run("/usr/bin/pgrep", ["-qf", "Contents/MacOS/StekTrustPlugin"]) != 0 { return }
            usleep(100_000)
        }
        run("/usr/bin/pkill", ["-9", "-f", "Contents/MacOS/StekTrustPlugin"])
        usleep(300_000)
    }

    @discardableResult
    static func launchctl(_ args: String...) -> Int32 { run("/bin/launchctl", args) }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    static func err(_ s: String) -> NSError {
        NSError(domain: "ru.edomost.safari", code: 1,
                userInfo: [NSLocalizedDescriptionKey: s])
    }
}

class ViewController: NSViewController, WKNavigationDelegate, WKScriptMessageHandler {

    @IBOutlet var webView: WKWebView!

    override func viewDidLoad() {
        super.viewDidLoad()
        webView.navigationDelegate = self
        webView.configuration.userContentController.add(self, name: "controller")
        webView.loadFileURL(
            Bundle.main.url(forResource: "Main", withExtension: "html")!,
            allowingReadAccessTo: Bundle.main.resourceURL!)

        // Перепроверять статус каждый раз, когда пользователь возвращается в приложение
        // (например, после включения расширения в Safari).
        NotificationCenter.default.addObserver(
            self, selector: #selector(appBecameActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if let w = view.window {
            w.setContentSize(NSSize(width: 560, height: 560))
            w.styleMask.remove(.resizable)
            w.title = "ЭДО Мост для Safari"
            w.center()
        }
    }

    @objc func appBecameActive() {
        checkStatus()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        checkStatus()
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? String else { return }
        switch body {
        case "open-preferences":
            SFSafariApplication.showPreferencesForExtension(withIdentifier: extensionBundleIdentifier) { _ in }
        case "check-status":
            checkStatus()
        case "service-on", "service-off":
            let turnOn = (body == "service-on")
            DispatchQueue.global(qos: .userInitiated).async {
                if turnOn {
                    do { try PluginService.enable() }
                    catch { NSLog("PluginService.enable: %@", error.localizedDescription) }
                } else {
                    PluginService.disable()
                }
                // Плагину нужна пара секунд, чтобы поднять HTTP-сервер.
                Thread.sleep(forTimeInterval: 2.0)
                DispatchQueue.main.async { self.checkStatus() }
            }
        case "open-moedelo":
            if let url = URL(string: "https://www.moedelo.org/") {
                if let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") {
                    NSWorkspace.shared.open([url], withApplicationAt: safari,
                                            configuration: NSWorkspace.OpenConfiguration())
                } else {
                    NSWorkspace.shared.open(url)
                }
            }
        default:
            if body.hasPrefix("resize:"), let h = Double(body.dropFirst(7)) {
                DispatchQueue.main.async {
                    self.view.window?.setContentSize(NSSize(width: 560, height: CGFloat(h)))
                }
            }
        }
    }

    /// Проверяет: 1) включено ли расширение в Safari; 2) доступен ли локальный плагин
    /// подписи; 3) включён ли фоновый режим плагина.
    func checkStatus() {
        SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: extensionBundleIdentifier) { state, _ in
            let enabled = state?.isEnabled ?? false
            self.checkPlugin { pluginOk in
                let svc = PluginService.state  // не на main: внутри короткий launchctl print
                DispatchQueue.main.async {
                    self.webView.evaluateJavaScript(
                        "if(window.updateStatus){updateStatus(\(enabled),\(pluginOk),'\(svc)');}")
                }
            }
        }
    }

    /// Пингует локальный плагин (СтекТраст/КриптоПро) на 127.0.0.1:18080.
    func checkPlugin(_ completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: pluginCheckURL) else { completion(false); return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            completion((resp as? HTTPURLResponse)?.statusCode == 200)
        }.resume()
    }
}
