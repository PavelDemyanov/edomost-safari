//
//  ViewController.swift
//  MoeDeloBridge
//
//  Нативный интерфейс (SwiftUI, системный стиль) — без WKWebView.
//

import Cocoa
import Combine
import SafariServices
import SwiftUI

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

// MARK: - Модель состояния

final class AppModel: ObservableObject {
    @Published var loaded = false        // первая проверка завершена
    @Published var extEnabled = false    // расширение включено в Safari
    @Published var pluginOk = false      // локальный плагин отвечает по HTTP
    @Published var service = "off"       // фоновый режим: on / off / noplugin
    @Published var busy = false          // идёт включение/выключение службы

    var allGood: Bool { extEnabled && pluginOk }

    /// Перепроверяет все три статуса; публикует результат на главной очереди.
    func refresh() {
        SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: extensionBundleIdentifier) { state, _ in
            let ext = state?.isEnabled ?? false
            self.checkPlugin { plugin in
                let svc = PluginService.state
                DispatchQueue.main.async {
                    self.extEnabled = ext
                    self.pluginOk = plugin
                    self.service = svc
                    self.loaded = true
                }
            }
        }
    }

    func setBackgroundMode(_ on: Bool) {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            if on {
                do { try PluginService.enable() }
                catch { NSLog("PluginService.enable: %@", error.localizedDescription) }
            } else {
                PluginService.disable()
            }
            Thread.sleep(forTimeInterval: 2.0)  // плагину нужно время поднять HTTP
            DispatchQueue.main.async { self.busy = false }
            self.refresh()
        }
    }

    func openSafariPreferences() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: extensionBundleIdentifier) { _ in }
    }

    func openMoeDelo() {
        guard let url = URL(string: "https://www.moedelo.org/") else { return }
        if let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") {
            NSWorkspace.shared.open([url], withApplicationAt: safari,
                                    configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func checkPlugin(_ completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: pluginCheckURL) else { completion(false); return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            completion((resp as? HTTPURLResponse)?.statusCode == 200)
        }.resume()
    }
}

// MARK: - Интерфейс (системный стиль)

struct BridgeView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            header

            GroupBox {
                VStack(spacing: 0) {
                    statusRow(title: "Расширение Safari",
                              ok: model.extEnabled,
                              okText: "Включено", badText: "Выключено")
                    Divider().padding(.vertical, 8)
                    statusRow(title: "Плагин подписи",
                              ok: model.pluginOk,
                              okText: "Запущен",
                              badText: model.service == "noplugin" ? "Не установлен" : "Не отвечает")
                    if !model.extEnabled {
                        Divider().padding(.vertical, 8)
                        Button {
                            model.openSafariPreferences()
                        } label: {
                            Label("Открыть настройки Safari…", systemImage: "safari")
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        Text("Поставьте галочку у «ЭДО Мост для Safari», затем вернитесь сюда — статус обновится сам.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    }
                }
                .padding(6)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Toggle("Запускать плагин в фоне", isOn: Binding(
                            get: { model.service == "on" },
                            set: { model.setBackgroundMode($0) }))
                        .toggleStyle(.switch)
                        .disabled(model.busy || model.service == "noplugin")
                        if model.busy {
                            ProgressView().controlSize(.small).padding(.leading, 4)
                        }
                    }
                    Text(model.service == "noplugin"
                         ? "Сначала установите плагин «Моё Дело» — тот же, что используется в Chrome."
                         : "Плагин будет запускаться при входе в систему и работать без значка в Доке. Если он завершится, macOS перезапустит его автоматически.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(6)
            }

            Button {
                model.openMoeDelo()
            } label: {
                Label("Открыть «Моё Дело»", systemImage: "arrow.up.forward")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.allGood)

            Text("Неофициальное приложение, не связано с сервисами ЭДО.\nНужны КриптоПро и плагин «Моё Дело» — те же, что для Chrome.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 440)
        .fixedSize()
    }

    // Шапка: крупный статус-символ + заголовок + подзаголовок.
    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: headerInfo.symbol)
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(headerInfo.color)
                .symbolRenderingMode(.hierarchical)
                .padding(.bottom, 2)
            Text(headerInfo.title)
                .font(.title2.weight(.semibold))
            Text(headerInfo.subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
    }

    private var headerInfo: (symbol: String, color: Color, title: String, subtitle: String) {
        if !model.loaded {
            return ("hourglass", .secondary, "Проверяю…",
                    "Смотрю состояние расширения и плагина подписи.")
        }
        if model.allGood {
            return ("checkmark.seal.fill", .green, "Можно подписывать",
                    "Откройте «Моё Дело» в Safari и нажмите «Подписать» — при первом разе подтвердите доступ.")
        }
        if !model.extEnabled {
            return ("puzzlepiece.extension", .orange, "Включите расширение",
                    "Подпись в Safari заработает после включения расширения в настройках.")
        }
        return ("exclamationmark.triangle.fill", .orange, "Плагин подписи не отвечает",
                model.service == "noplugin"
                ? "Установите плагин «Моё Дело» (КриптоПро) — без него подпись не работает."
                : "Запустите плагин «Моё Дело» или включите фоновый режим ниже.")
    }

    private func statusRow(title: String, ok: Bool, okText: String, badText: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(ok ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(ok ? okText : badText)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Хостинг SwiftUI в окне из storyboard

class ViewController: NSViewController {

    let model = AppModel()
    private var resizeSub: AnyCancellable?

    override func loadView() {
        // Окно описано в storyboard, но содержимое — полностью SwiftUI.
        view = NSHostingView(rootView: BridgeView(model: model))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Перепроверять статус каждый раз, когда пользователь возвращается в приложение
        // (например, после включения расширения в Safari).
        NotificationCenter.default.addObserver(
            self, selector: #selector(appBecameActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)

        // Высота контента меняется вместе с состоянием — подгоняем окно.
        resizeSub = model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.sizeWindowToFit() }
            }

        model.refresh()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if let w = view.window {
            w.styleMask.remove(.resizable)
            w.title = "ЭДО Мост для Safari"
            w.center()
        }
        sizeWindowToFit()
    }

    @objc func appBecameActive() {
        model.refresh()
    }

    private func sizeWindowToFit() {
        guard let w = view.window else { return }
        let size = view.fittingSize
        if abs(w.contentLayoutRect.height - size.height) > 1 {
            w.setContentSize(size)
        }
    }
}
