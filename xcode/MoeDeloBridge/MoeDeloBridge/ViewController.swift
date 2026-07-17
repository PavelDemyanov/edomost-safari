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

// MARK: - Служба подписи (нативный демон trustd)
//
// Заменяет вендорский StekTrustPlugin (x86_64, только через Rosetta) нашим
// нативным arm64-демоном, встроенным в приложение (Contents/Helpers/trustd).
// Демон поднимает HTTP на 127.0.0.1:18080 и транслирует запросы браузера
// (/TRUST/*) в CryptoAPI КриптоПро. Единственное внешнее требование —
// установленный КриптоПро CSP; вендорский плагин «Моё Дело» больше не нужен.
// «Фоновый режим» — LaunchAgent, который держит демон запущенным (автозапуск
// при входе, перезапуск при сбое). Всё обратимо и без прав администратора.

enum PluginService {
    static let label = "ru.edomost.trustd"
    static let vendorLabel = "StekTrustPlugin"        // вендорский агент — гасим, если остался
    static let legacyLabel = "ru.edomost.stektrust"   // наш старый агент под StekTrust — мигрируем
    static let vendorApp = "/Applications/StekTrustPlugin.app"  // старый x86-плагин вендора

    static var home: String { NSHomeDirectory() }
    static var gui: String { "gui/\(getuid())" }
    static var daemonBinary: String { Bundle.main.bundlePath + "/Contents/Helpers/trustd" }
    static var agentPlist: String { home + "/Library/LaunchAgents/\(label).plist" }
    static var daemonLog: String { home + "/Library/Logs/edomost-trustd.log" }

    /// Единственная внешняя зависимость — КриптоПро CSP.
    static var cspInstalled: Bool {
        FileManager.default.fileExists(atPath: "/opt/cprocsp/lib/libcapi20.4.dylib")
            || FileManager.default.fileExists(atPath: "/Library/Frameworks/CPROCSP.framework/CPROCSP")
    }
    /// Имя сохранено для существующих вызовов UI (теперь = «КриптоПро установлен»).
    static var pluginInstalled: Bool { cspInstalled }

    /// Старый вендорский плагин (x86, Rosetta) — если стоит, предлагаем удалить.
    static var oldPluginInstalled: Bool { FileManager.default.fileExists(atPath: vendorApp) }

    static var enabled: Bool {
        FileManager.default.fileExists(atPath: agentPlist) && launchctl("print", "\(gui)/\(label)") == 0
    }

    /// Состояние для UI: "on" / "off" / "noplugin" (нет КриптоПро).
    static var state: String {
        if !cspInstalled { return "noplugin" }
        return enabled ? "on" : "off"
    }

    static func enable() throws {
        let fm = FileManager.default
        guard cspInstalled else { throw err("КриптоПро CSP не установлен") }
        guard fm.fileExists(atPath: daemonBinary) else {
            throw err("Демон подписи не найден в приложении")
        }

        // 1. Освободить порт 18080: сперва снять наш агент (иначе KeepAlive воскресит
        //    демон под kill'ом), затем убрать старый StekTrust и любые копии демона.
        launchctl("bootout", "\(gui)/\(label)")
        migrateAwayFromStekTrust()
        killDaemonProcesses()

        // 2. Наш агент: автозапуск при входе + перезапуск при сбое.
        let agent: [String: Any] = [
            "Label": label,
            "ProgramArguments": [daemonBinary, "18080"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",
            "AssociatedBundleIdentifiers": ["ru.edomost.safari"],
            "StandardErrorPath": daemonLog,
            "StandardOutPath": daemonLog,
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
        killDaemonProcesses()
    }

    /// Миграция со старых версий: гасим наш прежний агент под StekTrust,
    /// теневой бандл и вендорский автозапуск, чтобы освободить порт 18080.
    static func migrateAwayFromStekTrust() {
        launchctl("bootout", "\(gui)/\(legacyLabel)")
        try? FileManager.default.removeItem(atPath: home + "/Library/LaunchAgents/\(legacyLabel).plist")
        try? FileManager.default.removeItem(
            atPath: home + "/Library/Application Support/ЭДО Мост для Safari/StekTrustShadow")
        launchctl("bootout", "\(gui)/\(vendorLabel)")
        launchctl("disable", "\(gui)/\(vendorLabel)")
        run("/usr/bin/pkill", ["-f", "Contents/MacOS/StekTrustPlugin"])
    }

    /// Полностью убирает старый вендорский плагин: гасит автозапуск и процессы,
    /// переносит .app в Корзину. Возвращает true, если его больше нет.
    @discardableResult
    static func removeOldPlugin() -> Bool {
        launchctl("bootout", "\(gui)/\(vendorLabel)")
        launchctl("disable", "\(gui)/\(vendorLabel)")
        run("/usr/bin/pkill", ["-f", "Contents/MacOS/StekTrustPlugin"])
        usleep(500_000)
        guard FileManager.default.fileExists(atPath: vendorApp) else { return true }

        // Если плагин ставился перетаскиванием — принадлежит пользователю, уходит в Корзину без прав.
        if (try? FileManager.default.trashItem(at: URL(fileURLWithPath: vendorApp),
                                               resultingItemURL: nil)) != nil, !oldPluginInstalled {
            return true
        }
        // Инсталлятор «Моё Дело» ставит его от root — перенос между папками требует прав.
        // Просим права администратора (штатный диалог macOS) и переносим в Корзину.
        // Сначала убираем возможную прежнюю копию в Корзине (иначе mv в непустую папку падает).
        let sh = "/bin/rm -rf '\(home)/.Trash/StekTrustPlugin.app'; /bin/mv -f '\(vendorApp)' '\(home)/.Trash/'"
        let apple = "do shell script \"\(sh)\" with administrator privileges"
        run("/usr/bin/osascript", ["-e", apple])
        return !oldPluginInstalled
    }

    /// Останавливает наш демон и любые копии StekTrust; ждёт освобождения порта.
    static func killDaemonProcesses() {
        run("/usr/bin/pkill", ["-f", "Contents/Helpers/trustd"])
        run("/usr/bin/pkill", ["-f", "Contents/MacOS/StekTrustPlugin"])
        for _ in 0..<30 {  // до 3 секунд
            let a = run("/usr/bin/pgrep", ["-qf", "Contents/Helpers/trustd"])
            let b = run("/usr/bin/pgrep", ["-qf", "Contents/MacOS/StekTrustPlugin"])
            if a != 0 && b != 0 { return }
            usleep(100_000)
        }
        run("/usr/bin/pkill", ["-9", "-f", "Contents/Helpers/trustd"])
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
    @Published var oldPlugin = false     // установлен старый x86-плагин StekTrust

    var allGood: Bool { extEnabled && pluginOk }

    /// Перепроверяет все три статуса; публикует результат на главной очереди.
    func refresh() {
        SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: extensionBundleIdentifier) { state, _ in
            let ext = state?.isEnabled ?? false
            self.checkPlugin { plugin in
                let svc = PluginService.state
                let old = PluginService.oldPluginInstalled
                DispatchQueue.main.async {
                    self.extEnabled = ext
                    self.pluginOk = plugin
                    self.service = svc
                    self.oldPlugin = old
                    self.loaded = true
                }
            }
        }
    }

    func setBackgroundMode(_ on: Bool) {
        busy = true
        // Запоминаем ручной выбор: если выключили — автозапуск при следующем старте не поднимет службу.
        UserDefaults.standard.set(!on, forKey: "serviceUserDisabled")
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

    /// Удаляет старый вендорский плагин (в Корзину) и сразу включает нашу службу.
    func removeOldPlugin() {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            PluginService.removeOldPlugin()
            do { try PluginService.enable() }
            catch { NSLog("enable after removeOldPlugin: %@", error.localizedDescription) }
            Thread.sleep(forTimeInterval: 2.0)
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

// MARK: - Иконка «МоеДело.Плагин»
// Вшита в код (vendor SVG): ресурсы приложения перечислены в pbxproj пофайлово,
// и добавление файла туда — отдельная хирургия. NSImage рендерит SVG сам (macOS 11+).

private let pluginIconB64 = "PD94bWwgdmVyc2lvbj0iMS4wIiBlbmNvZGluZz0iVVRGLTgiPz4KPHN2ZyBpZD0iX9Ch0LvQvtC5XzEiIGRhdGEtbmFtZT0i0KHQu9C+0LlfMSIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIiB2ZXJzaW9uPSIxLjEiIHZpZXdCb3g9IjAgMCA5MzIuNTE4IDg1MS4yIj4KICA8IS0tIEdlbmVyYXRvcjogQWRvYmUgSWxsdXN0cmF0b3IgMzAuNC4wLCBTVkcgRXhwb3J0IFBsdWctSW4gLiBTVkcgVmVyc2lvbjogMi4xLjQgQnVpbGQgMjI2KSAgLS0+CiAgPHBhdGggZD0iTTkyNi44OTUsNjguNjhjLS4xODcsNS45NDMsOC4xNDUsOC4wNTQsNy4xODksMTQuODY5LTMuMTU1LS4yODgtNC4zODgtMy4wOTctNi4wODgtNi43MjItMS43MzUsMy4yNzQtLjk1Myw2LjAxNC0uOTUzLDguNzU2bC0uMDA0LDUyMS4yYy00Ljg3Ny0xLjMwOS03LjM2OC01LjcwNC0xMC45MjQtOS4yNzhsLTQ2LjM0LTQ2LjU2NWMtMS43NjQtMS43NzMtMy4yMjQtMi44NjMtNS41ODMtMi4yNjlsLS4xMTUtMTcuOTAzLTE2LjE3NC4xMzNjLS4wNjktMS4xOTUtLjUzNy0yLjQ5NS0xLjY0Ni0zLjU0OGwtOS43MjUtOS4yMzdjLTIuMDkyLTEuOTg3LTMuNTY4LTMuNTI1LTUuNTQyLTUuNTU1bC0xNS4wNTItMTYuMDg5LDQ4LjEzLjAzNi4wNjItMjkuNTg5LTc3LjE3LjAwMi0zLjA1Ny4wMDVjLS4wMjktMS4zNTMtLjU5Mi0yLjQwNS0xLjcxNC0zLjUyMWwtMjcuNTcyLTI3LjQzYy0xLjE5MS0xLjE4NS0yLjg1Ny0xLjY1Ny0yLjYxNi0zLjQzNWgxMTIuMDU1cy4wODktMjkuNzU1LjA4OS0yOS43NTVsLTE0MS4xNzktLjA1MS0zLjA4MS4wODJjLS4xLTIuMTAxLTEuOTk5LTMuODA1LTMuNjY4LTUuNGwtMTEuMzAyLTEwLjgwNC0yOS4zMjktMjkuNi0yOS4xNDMtMjguODI4LTYuMDE1LTYuMTE3LTExLjA2Mi0xMC43ODEtNy43MDYtOC41ODQsMjQyLjQ5OC0uMTQ2LS4xNDEtMS44MWMuNzQxLjEzLDEuNjA1LS4xMTEsMS45NDYtLjYxMXMtLjA1OC0xLjIwOC0uNTYxLTEuMjgxbC0xLjMyMi0uMTkzLS4wMjQtNDUuNzUtMjk2LjEzNy0uMTY3Yy4zNDktMy43MTMtMi42MjMtNS42MTctNS4wNTQtOC4wNTdsLTEzLjg5OC0xMy45NTFjLTIuNjQ0LTIuNjU0LTQuNTk5LTQuMjk0LTcuMzM0LTcuMDI3bC0xNTUuNTc3LTE1Ny4wOTMsNTM3LjY1MS0uMDEyYzEuODAzLDAsMi4zNzcuMDQ2LDIuOTM4LjY5Mi4yNDUuMjgzLjI5OS45NzkuMjU0LDEuMzhaTTg2NC4wOTYsMTc2LjkwOWwuMDk1LTI5Ljc2LTIwMy41MTUuMDA3LjE5MSwyOS43OTksMjAzLjIyOS0uMDQ2WiIgZmlsbD0iI2YyZjNmMyIvPgogIDxwYXRoIGQ9Ik0xNTAuODY3LDM2LjY1MWw0LjE4Ni4xMTRjLTEuMjU3LDIuMTg3LTMuODk1LDMuMTg2LTUuODQ5LDUuMTgzbC0zMS4wMzksMzEuNzAzYy0xLjk5OS42NjEtMy40ODYsMi4yMTktNC4zNDUsNC40OTMtMi41NjkuNTA0LTUuMzQ4LDQuODYyLTcuMzU4LDYuODc1bC00Mi4wNTUsNDIuMTEyYy05LjgyMSw5LjgzNC0xNS40NjYsMjIuOTc0LTE5LjgzNiwzNS40NDEtOS43NjgsMjcuODczLTcuMjgxLDU3Ljk3OSw1LjQyOCw4NS4wNjcsNS44MTksMTIuNDA0LDE0LjMwNCwyMi4zNiwyMy42ODksMzIuMjk0bDE0LjEyMywxNC45NDksNDEuOTg0LDQxLjg4MSw2LjA2NCw2LjEzMiw3Ni44ODEsNzYuOTIxLDE2LjQ5OSwxNi40MTYsMzEuNTUzLDMxLjY2NiwxNy43MDIsMTcuMjQzLDExLjE0MiwxMS44NCwyMS4zMjMsMjAuNjQ0YzMuNjYsMy41NDMsNi44Nyw2Ljk2OSwxMC41MTYsMTAuNjAzbDI1LjQ2MSwyNS4zNzksNi4xNTksNi4wNDksNDIuODYxLDQyLjg0OSw3LjA0Niw3LjIyMywxNi4zNjgsMTYuMzczLDEyLjc5NywxMy4wMjJjMy4zMjYtMS42MTIsNi4wNTYtMy45NjYsOC42MjktNi42MzJsMTIuMjc2LTEyLjcxNywyLjctMy4zMDMsMTUuMjQ1LDE1LjM1MS0xMC40ODQsMTEuNTA5LTE5LjE0MiwxOC43MzctMTUuNDkzLTE0LjkzNy0xMi4xNTUsMTIuNjM3LTI5LjQyOC0yOS41ODktNS40NzUtMy4zMDRjLS4wOC0xLjYxNC0xLjM4My0zLjA2NS0yLjcyOC00LjQxbC0zMi45NTItMzIuOTUxLTQuNjEtNC43NEwzNS4zMzIsMjgxLjUzNWMtOC4wNzMtOC4wNzMtMTIuNjg1LTE3Ljg5NS0xOC4zNDEtMjYuODYybC0uMDIxLS45MjVjLS4wMjEtLjkxMS0uNDc5LTEuNjEtLjc2My0yLjM1Ni01LjU5Ny0xNC42OTctOC4zOTEtMjguNTg4LTguNzIzLTQ0LjIwNi0uMTAyLTQuNzgsMS4zNy05LjU1OC4zMjktMTQuNTc4LDIuMDk2LS44OTIsMS40NjMtMy4zMTQsMS44NTEtNS4zMjcsMS45OTItMTAuMzU3LDUuODM1LTE5LjcyLDEwLjI0LTI4LjczOS43NC0xLjUxNSwxLjQ4NS0zLjIwNywyLjI4NS00LjY1NC44OTctMS42MjEsMi44MTUtMi45OTIsMi44NjUtNS4zNzMsMS40MzctLjA5NSwyLjYxMS0yLjQ3NywyLjg1Mi0zLjY3NS45OTgtLjQ3NCwxLjczMS0xLjI3NywxLjkxNy0yLjQwNEwxMjIuNjk2LDQ5LjYwMWwxMC40NzktNi45MDNjMi41NTQuNDIyLDEyLjIzOC02LjE5NSwxNy42OTItNi4wNDdaIiBmaWxsPSIjMWE2MDlmIi8+CiAgPHBhdGggZD0iTTM4Ni4wNTMsNjYuNjJsMTU1LjU3NywxNTcuMDkzYzIuNzM1LDIuNzMzLDQuNjksNC4zNzMsNy4zMzQsNy4wMjdsMTMuODk4LDEzLjk1MWMyLjQzMSwyLjQ0LDUuNDAzLDQuMzQ0LDUuMDU0LDguMDU3bC03NS4xNDUuMDIyLTE5LjMxMy0xOS43NTgtOTEuMDEzLTkxLjAxMmMxLjM0My0uOTg2LDEuNTM3LTIuNDA2LDEuNTE4LTQuMzAzbC0uNTE4LTUyLjc2NmMtMy4zMjUsMy40NC0yLjk5Nyw3Ljg1OC0zLjA4NSwxMS44NDdsLS43MzYsMzMuNTUzYy0uMDI1LDEuMTU2LTMuMDk3LDIuOTY1LTEuMTU5LDQuOTc2LjkwOS45NDMsMS41NTEsMi41NywxLjA0LDMuOTI2LTIuMTY0LTIuMDM3LTQuMDA2LTQuMTM5LTYuMDA2LTYuMTc0bDIuMjc5LTMuNTU3LjcyOS0xNy4wNjhjLjE1LTMuNTAzLS4wNjItNi41Ny4yLTEwLjE5M2wuOTI2LTEyLjgxMWMuMzYtNC45ODEsMS41OTUtOS4zNzQsNS45NTItMTIuMTI2bC4yNTgtNS41NWMuMDM4LS44MjQtLjUwMy0yLjczNy4wODQtMy40ODYuMzg3LS40OTQsMi4yLjA5LDIuMTI2LTEuNjQ2WiIgZmlsbD0iI2U2ZWFlYiIvPgogIDxwYXRoIGQ9Ik0zODMuODQyLDcxLjc1MWwtLjI1OCw1LjU1Yy00LjM1NywyLjc1Mi01LjU5Miw3LjE0Ni01Ljk1MiwxMi4xMjZsLS45MjYsMTIuODExYy0uMjYyLDMuNjIzLS4wNSw2LjY5MS0uMiwxMC4xOTNsLS43MjksMTcuMDY4LTIuMjc5LDMuNTU3LTIzLjIyMS0yMy43OTZjMy45OTItMS43MTQsMi43ODYsNS4wMTQsMTAuNDYyLDYuNjI1bDIuMDg0LDUuMjI5LDkuNjQyLTMuMDE2Yy0uOTI0LTIuNzM3LTEuNTI0LTMuNDItMi45MjgtNS41MjEsMi4zODYtMS44NTguNDg5LTUuMTQyLDEuMDQzLTYuNzEzLDEuNDU0LTQuMTI2LjI1MS03Ljk5OS43MzMtMTIuMjIybDEuMjA1LTEwLjU2M2MuNzQyLTYuNTA4LDUuMzk4LTExLjY1OCwxMS4zMjUtMTEuMzNaIiBmaWxsPSIjZjJmM2YzIi8+CiAgPHBhdGggZD0iTTI3Ni40MDksMzYuODEyYzEuOTgzLDIuNiw1LjA3MiwzLjk2Niw3LjMwNSw2LjIxMWwxLjgwMiwxLjgxMSw2LjIxNyw2LjE4NGMuNjMuNjI3LDEuMDgsMS42NjQsMi4yNDIsMS42MDQtLjE1MSwxLjM1OS43MzIsMi4wODIsMS44NDgsMi40ODhsMS43ODYsMS43NDUsNTIuMDI4LDUyLjI0NGMuMjY4LS4xMjcuNS4wMDUuNjQyLjE2M2wyMy4yMjEsMjMuNzk2YzIsMi4wMzUsMy44NDIsNC4xMzcsNi4wMDYsNi4xNzRsMi45MzksMi43NjcsOTEuMDEzLDkxLjAxMiwxOS4zMTMsMTkuNzU4YzEuMzgzLDEuNDE1LDIuOTM0LDEuMDEyLDUuMjE3LDEuMDA3bDczLjg5NC0uMTYzYy44OTctLjAwMiwxLjMwOC41NTksMS40NzQuOTU3bC03Ny4yNTkuNTE5Yy0zLjg2NC4wMjYtNy42MjctMS44NjUtOS43NTctNS43MjUtLjI2NC0xLjIxNC0uODQtMi4yNjktMS43NTMtMi44NTItLjg0LS41MzctMi4xNjUtLjc1Ni0zLjkzNi0uMDIzLTEuNDE3LTQuNjQ3LTUuMjc0LTEwLjIzMy05LjMyNy0xMC4yODMuMTE0LTQuMjU5LTMuNDIzLTUuNjc0LTUuNzk1LTguMDg0LTMuMTQtMy4xOS01LjUyOC02LjEzLTkuMDk0LTkuMTI1LTEuOTMxLTEuNjIyLTMuODU4LTQuOTIxLTcuMjUyLTQuODctLjg2OS00Ljk5Mi00Ljk1OS03LjI2OS04LjE1Mi0xMC41MTZsLTcuODI5LTcuOTYyLTcuMjgxLTYuNzY4Yy0zLjUyLTMuMjcyLTUuNzc5LTYuNTk0LTkuNDI3LTkuOTA2LTMuMTI1LTIuODM4LTQuOTItNy43NzQtMTAuMzY5LTYuNiwxLjM4OS0zLjIxMS0uMTc1LTUuMzM4LTIuNDgxLTYuMzkxLTIuODkzLTEuMzIyLTQuMzc2LTQuODYtNi42LTYuMjQ4LTMuMzU1LTIuMDk0LTQuNzQ1LTUuNDIxLTcuNDYxLTcuNjAzLTYuNTQtNS4yNTQtMTEuNDI3LTEwLjg5Mi0xNy4wNzMtMTcuMTI0LTIuNjk1LTIuOTc0LTYuOTk0LTYuMDUtOS42MDctOS4xM2wtNC4yNDYtNS4wMDVjLTEwLjAxLTYuODkyLTE1LjI2NC0xNS43NDYtMjUuMDQyLTI0LjgwOS0yLjgyMy0yLjYxNi00LjMwNy00LjMyOC03LjE3Ny03LjE0NGwtMTMuNjAzLTEzLjM0NGMtMi40ODktMi40NDItMy41MTUtNS4xNjMtNi45MTItNy4wNzMtNS4xODMtMi45MTQtOS4wNzYtOC40MjMtMTIuMzQ3LTEzLjQzNS0zLjc4NC0uNjI1LTYuNDE3LTIuNjcxLTcuNzk4LTYuMzI0bC00LjIyNi0zLjUyMmMtMi4wNS0zLjg3My01LjE1OC01Ljc1My04Ljg2Ny03LjUxOC0uODE3LS44NDgtMS40MTItMi43NjMtMy4zMDktMy42NDdsLTEyLjA1OS01LjYxOGMtMi42NzYtMS4yNDctMy41NjItMi4wMTEtNS44MS0zLjE5Ni03LjM5OC0zLjg5OS0xNi40NTEtNC41NTEtMjUuNzAzLTYuMTYzLTE0LjMyOC0yLjQ5Ni0yNC44MzksMS45MTMtMjkuOTA3LDEuNzktMy41NzktLjA4Ny03LjM0NiwyLjE3NC0xMC42MjYsMi45MDQtNS4zOTQsMS4yMDEtOS42NzksMi43MjMtMTQuMTk1LDUuOTUzLTMuMzA4LDIuMzY2LTcuNDc2LDMuNTIzLTEwLjgzMiw2LjIxLTEuMzY2LDEuMDkzLTMuODguODYzLTUuMTg2LjgyOGwtNC4xODYtLjExNGMxLjYyMy0xLjksNS4xMzUtMS4xNTMsNy40OTUtMi40NThsMTQuMjc4LTcuODkyYzkuMjQ4LTUuMTEyLDE5LjQwNy02LjkyOSwyOS45MjgtOS4xMjQsMjcuNTg4LTIuODYsNTIuMzAxLDMuMzcyLDczLjg0LDE5LjYzNloiIGZpbGw9IiMyZTg0Y2QiLz4KICA8cGF0aCBkPSJNMzQ5LjYzNSwxMDkuMDk5bC01Mi4wMjgtNTIuMjQ0YzEuNDEtLjIzNywyLjI0My41MzIsMy40MiwxLjcybDcuOTgsOC4wNTVjMy4zNTUtLjAxNyw1LjA1NCwyLjM3LDQuOTM5LDUuNzc3LDMuODIxLS42NzksMy42NywyLjgyNSw0Ljk5MSwzLjk1NywyLjI1NSwxLjkzMiw1LjIwNSwyLjMyNiw1LjIxNSw2LjE4N2w1LjkzMy45NWMtMS44NjEsNC4wMSwxLjU3NSw0Ljc0MSwyLjU3Miw2LjE4MiwxLjk4MywyLjg2NCwzLjc5NCw0LjE5NCw2LjQ0OSw2LjAwNSwxLjI4OS44NzksMS43MDksNC41MzcsNS4yNCwzLjQ2MSwxLjY3NSw2LjQyMyw1LjkzNCw3LjA5NCw1LjI4OCw5Ljk1MVoiIGZpbGw9IiNmMmYzZjMiLz4KICA8cGF0aCBkPSJNMjgzLjcxNCw0My4wMjNjLTIuMjMzLTIuMjQ1LTUuMzIxLTMuNjEtNy4zMDUtNi4yMTEsMy43NzItLjk1MSw2LjczNywyLjk3MSw3LjMwNSw2LjIxMVoiIGZpbGw9IiNmMmYzZjMiLz4KICA8cGF0aCBkPSJNMjk1LjgyMiw1NS4xMWMtMS4xMTYtLjQwNi0xLjk5OC0xLjEyOS0xLjg0OC0yLjQ4OC43NDQtLjAzOCwxLjY0NS4xMzUsMS44NjEuNjY2LjIzNS41NzYuMTIyLDEuNTA0LS4wMTMsMS44MjJaIiBmaWxsPSIjZjJmM2YzIi8+CiAgPHBhdGggZD0iTTI5MS43MzIsNTEuMDE4bC02LjIxNy02LjE4NGMyLjkxOC40OTUsNS43OTMsMy4yOCw2LjIxNyw2LjE4NFoiIGZpbGw9IiNmMmYzZjMiLz4KICA8cGF0aCBkPSJNOTI3LjAzOCw2MDYuNzgzbC0uMDg5LDE5NS42ODQuMjM5LDI2LjI4OC02LjEyNi4zMTktNTMzLjIyLS4wMDdjLS40MTQuMjA3LTMuMjY0LjI3LTQuMTQtLjYxNWwuMzItMTY4LjAyMSwyOS43NjEsMjguNzA3LDEzLjI0NC0xMy4yNjcsMTQuMzI0LDE0LjYwNiwxOC4wMDgtMTcuNzM1LDE4LjI2OSwxOC40NzQsMTA5LjMwNiwxMDguOTgxLDE4Mi40MDktMTgyLjM4NWMtMi45MzMtNC4zNzQtNi4yODEtNy44NzItOS45OTctMTAuNTE3LTEuNDA1LTEtMi4wNTItNC4yMjctNC43MDktNC44NjdsMTQuODQtMTQuODMzLTI2Ljc1My0yNi43MjUsMTIxLjIxNy0uMzE2LjI0OS0xMS44ODJjMi4zNTktLjU5NCwzLjgxOS40OTYsNS41ODMsMi4yNjlsNDYuMzQsNDYuNTY1YzMuNTU2LDMuNTc0LDYuMDQ3LDcuOTY5LDEwLjkyNCw5LjI3OFpNODY0LjA4Nyw3NjguMTE0bC0uMTExLTI5LjI4Ny0yMDMuMDMzLjA2NC0uMTc4LDI5LjM0MSwyMDMuMzIyLS4xMThaIiBmaWxsPSIjZTZlYWViIi8+CiAgPHBhdGggZD0iTTU2Ny45MTUsMjUyLjc0N2wyOTYuMTM3LjE2Ny4wMjQsNDUuNzUtLjA2MiwyLjA4NS4xNDEsMS44MS0yNDQuNDA2LS4zOTMtNzQuNjY5LjM4NGMtLjc2Ny4wODktMS4xODEuNTk5LTEuMTY0LDEuMjI0bC0xLjYzNy0xLjY4Niw3Ny4xMzUtLjg2Ni00Ni4wNTktNDYuNjUyYy0uMTY2LS4zOTgtLjU3Ny0uOTU5LTEuNDc0LS45NTdsLTczLjg5NC4xNjNjLTIuMjgzLjAwNS0zLjgzMy40MDgtNS4yMTctMS4wMDdsNzUuMTQ1LS4wMjJaIiBmaWxsPSIjOTVkOGY4Ii8+CiAgPHBhdGggZD0iTTg2NC4xNTUsMzAyLjU2bC0yNDIuNDk4LjE0Niw3LjcwNiw4LjU4NCwxMS4wNjIsMTAuNzgxLDYuMDE1LDYuMTE3LDI5LjE0MywyOC44MjgsMjkuMzI5LDI5LjYsMTEuMzAyLDEwLjgwNGMxLjY2OSwxLjU5NSwzLjU2OCwzLjMsMy42NjgsNS40bC03MC45MjEtLjA4NWMtMi4wNDMtLjAwMi0zLjY3OC4yMzQtNS4yNjMuOTkxbC0zNi4wOTktMzUuNTUxYy0zLjczNC0zLjY3OC03Ljk2NC02LjQ0Ni0xMC42NTktMTAuNTIzLTEuNTctMi4zNzYtMy42NDQtNC43MDctNi4yNy01LjkxOC0uMDY5LS4zOTctLjIwOS0uOTc3LS41Mi0xLjI5MWwtNDYuMjM2LTQ2LjY2N2MtLjAxNy0uNjI1LjM5Ny0xLjEzNSwxLjE2NC0xLjIyNGw3NC42NjktLjM4NCwyNDQuNDA2LjM5M1oiIGZpbGw9IiNlNmVhZWIiLz4KICA8cG9seWdvbiBwb2ludHM9Ijg2NC4wOTYgMTc2LjkwOSA2NjAuODY3IDE3Ni45NTUgNjYwLjY3NiAxNDcuMTU2IDg2NC4xOTEgMTQ3LjE1IDg2NC4wOTYgMTc2LjkwOSIgZmlsbD0iI2NmZDVkNiIvPgogIDxwYXRoIGQ9Ik04MTMuMDU5LDQ5Ni41MjZsMi44NzctLjA1MywxNS4wNTIsMTYuMDg5YzEuOTc0LDIuMDMsMy40NTEsMy41NjgsNS41NDIsNS41NTVsOS43MjUsOS4yMzdjMS4xMDksMS4wNTMsMS41NzcsMi4zNTMsMS42NDYsMy41NDhsLTEzNC41NDcuNTc3LTM0LjcxMi0zNC41NzYsMTM0LjQxNi0uMzc3WiIgZmlsbD0iI2U2ZWFlYiIvPgogIDxwb2x5Z29uIHBvaW50cz0iODQ3LjkwMiA1MzAuOTAyIDg2NC4wNzYgNTMwLjc2OSA4NjQuMTkxIDU0OC42NzEgODYzLjk0MSA1NjAuNTU0IDc0Mi43MjQgNTYwLjg3IDcxMy4zNTUgNTMxLjQ3OSA4NDcuOTAyIDUzMC45MDIiIGZpbGw9IiNiZWM2YzgiLz4KICA8cGF0aCBkPSJNNjYyLjg3MSw0NjYuODY0bDEyMS4wMy4wNjUsMy4wNTctLjAwNWMtLjIzMiwxLjU5NC41NjQsMi42NTIsMS44NDgsMy44NzlsMTYuODY3LDE2LjEyMmMyLjQxMyw0LjQ4Miw3LjA2Myw2LjI5NCw3LjM4Nyw5LjYwM2wtMTM0LjQxNi4zNzctMTkuNTQ2LTE5LjY1Mi0uMjEzLTkuOTYyLDMuOTg3LS40MjVaIiBmaWxsPSIjYjJiYWJjIi8+CiAgPHBhdGggZD0iTTc1Miw0MzIuNTQzbC0yLjg1My4wNzJjLjE5LTEuNjYtLjYzNC0yLjgxNC0yLjAwOS00LjE2MmwtMTUuMTItMTQuODE1LTcuMDE0LTcuMDk2Yy0xLjEwMi0xLjExNS0yLjMwOC0yLjE1Ni0yLjAzOS0zLjgwNWwxNDEuMTc5LjA1MS0uMDg5LDI5Ljc1NGgtMTEyLjA1NVoiIGZpbGw9IiNjZmQ1ZDYiLz4KICA8cGF0aCBkPSJNNzQ5LjE0Niw0MzIuNjE1bDIuODUzLS4wNzJjLS4yNDIsMS43NzgsMS40MjQsMi4yNSwyLjYxNiwzLjQzNWwyNy41NzIsMjcuNDNjMS4xMjIsMS4xMTYsMS42ODUsMi4xNjgsMS43MTQsMy41MjFsLTEyMS4wMy0uMDY1LjQ1OS0xMi40MDdjLjA3Mi0yLjE5NC0yLjM5NS00LjI5My0zLjY0Mi01LjEwNy0xLjY5NS0xLjEwOC00LjA1My0uNDQ0LTYuMDIyLjA5OGwzLjU1NS00LjMxMy0xMS4zODItMTEuODA1Yy40NDMtLjMwMSwxLjA5Ny0uNzYzLDIuMTU3LS43NjJsMTAxLjE1MS4wNDlaIiBmaWxsPSIjZTZlYWViIi8+CiAgPHBhdGggZD0iTTcxOS44ODMsNDAyLjgxOWwzLjA4MS0uMDgyYy0uMjY5LDEuNjUuOTM3LDIuNjkxLDIuMDM5LDMuODA1bDcuMDE0LDcuMDk2LDE1LjEyLDE0LjgxNWMxLjM3NSwxLjM0OCwyLjIsMi41MDEsMi4wMDksNC4xNjJsLTEwMS4xNTEtLjA0OWMtMS4wNiwwLTEuNzE1LjQ2MS0yLjE1Ny43NjJsLTIuNDM5LTEuODc1Yy0xLjAxMy0uNzc5LTEuMDE3LTIuMDcyLS40MDgtMi45NjZsMTIuODI2LTEyLjQ5Ny0xMi4xMTktMTIuMjY1YzEuNTg1LS43NTcsMy4yMjEtLjk5Myw1LjI2My0uOTkxbDcwLjkyMS4wODVaIiBmaWxsPSIjYmVjNmM4Ii8+CiAgPHBhdGggZD0iTTgxNS45MzYsNDk2LjQ3M2wtMi44NzcuMDUzYy0uMzI0LTMuMzA4LTQuOTc0LTUuMTIxLTcuMzg3LTkuNjAzbC0xNi44NjctMTYuMTIyYy0xLjI4NC0xLjIyNy0yLjA4LTIuMjg0LTEuODQ4LTMuODc5bDc3LjE3LS4wMDItLjA2MiwyOS41ODktNDguMTMtLjAzNloiIGZpbGw9IiNiZWM2YzgiLz4KICA8cGF0aCBkPSJNODY0LjAxNCwzMDAuNzQ5bC4wNjItMi4wODUsMS4zMjIuMTkzYy41MDQuMDczLjkwNC43OC41NjEsMS4yODFzLTEuMjA1Ljc0LTEuOTQ2LjYxMVoiIGZpbGw9IiNlNmVhZWIiLz4KICA8cGF0aCBkPSJNMjcyLjMxOSw3Mi44NGMyLjYyMy0uMzEyLDMuODAyLjY2NSw2LjE4MSwyLjM1bDEwLjI2LDcuMjY1YzQuMTg1LDIuOTYzLDkuNjQ2LDEwLjExOSwxMy42MjUsMTUuNjk2LDIuNDY1LDMuNDU2LDUuMzk3LDUuMjI0LDguMzMyLDguMDYzLDEuNzk5LDEuNzQxLDMuMjQ4LDMuNDg5LDUuMjIyLDUuNDY0bDE1LjU0OSwxNS41NTFjNy4wNzEsNy4wNzEsMTMuNDYsMTQuMjQ4LDIzLjUzNiwxNy40NzIsMS4yMjcuOTA0LDIuODk3LDMuNTYsNC45NDMsNC4yLDIuMTAyLDguNjU3LDkuMjc3LDE0LjM2MiwxNC45NzIsMjAuNjUzLDIuMDQzLDIuMjU3LDEuOTI3LDMuODk2LDUuMzcxLDUuMzY0LDIuMzU2LDEuMDA0LDUuMDYzLDUuMTY2LDcuMTEzLDcuMTIybDYuNjc1LDYuMzY1YzIuNDI5LDIuMzE2LDMuMDgxLDYuMDE4LDYuMzI2LDcuODMxLDMuMjcyLDUuODYxLDguMjg3LDkuODU4LDE0LjUxMiwxMi4zNzcsMS4wMTcsNS4wNzQsNC44MzgsOC4yMTIsOS45NzgsNy45NCwxLjg0MSwxLjk2MSw0LjM0NCwxLjgwNSw2LjYwNywyLjc5LDIuNzU1LDEuMiwzLjIxMiw2Ljc1NSw1LjE2Miw4LjI2NiwzLjkxNiwzLjAzMywzLjYxLDUuNDQyLDUuMjQ4LDkuMzU1LDEuNjk3LDQuMDU2LDYuMjgxLDkuMDIxLDkuOTM3LDExLjY3NCw0LjEzMiwyLjk5OCw5LjQ2MiwzLjk5MiwxMi44MzQsOC4zNzUsMS41NjQsMi4wMzMsNC4wMjcsNC4yNDEsNi4xNjcsNS43MTguNjcyLDUuMDE4LDIuNzUzLDEwLjE5Niw3Ljc2OCwxMi4xNjIsMi45OTUsMS4xNzQsMy41NDIsNC4wNDIsNS4yODYsNS42MDNsMTAuNzIyLDkuNmMxLjc3MywxLjU4Nyw0LjE4NSw0LjI4Niw1LjgxOSw1LjQxNiwzLjQwMSwyLjM1NCw2LjIzOSwyLjQ2Myw4Ljc0NCw2LjExNiwyLjc1OSw0LjAyNSw3LjY3OCw3LjA2MywxMS40LDEwLjU4OCwyLjI3MywyLjE1MiwyLjk2Nyw2LjExMyw2LjMxOCw3LjUyMywzLjI5MiwxLjM4NiwzLjk4MSw0LjIxNSw0LjAzNyw3LjgzMSw3LjU0NCwxLjkzOCwxMi41MDMsOS4wNjIsMTYuOTIxLDEzLjIzNSwzLjcyMiwzLjUxNSw3LjM2NCw2LjE1NywxMC4yLDEwLjk0NCwxLjA2OSwxLjgwNCwzLjkwNCwzLjU4Niw1Ljc1Myw1LjIwNiwzLjc0OSwzLjI4NSwxMS4yMSwzLjkxMSwxNS4wMjYsMS45OTVsLjk2NS0yLjkyNGMuMTYyLS40OTEsMS43MTUtLjYzNSwxLjg3NC4zMDguMDg3LjUxOS4yMTksMS45ODYsMS4xODksMi41NDdsNC41NDQtNC42MDUuNTYxLTIuOTM3Yy4xMi0uNjI3LDEuMzEyLTEuMDQ3LDIuMTUzLS44OTQuMzExLjMxNC40NTEuODk0LjUyLDEuMjkxLTEuMDMxLDEuNjI0LDIuNzM5LDYuNjQ4LDIuOTQ1LDYuNzQyLjg5Ny40MSwyLjUxMy0uMzQ1LDMuMzI1LS44MjQsMi42OTQsNC4wNzcsNi45MjQsNi44NDYsMTAuNjU5LDEwLjUyM2wzNi4wOTksMzUuNTUxLDEyLjExOSwxMi4yNjUtMTIuODI2LDEyLjQ5Ny0xNC43MTUsMTQuNzQ5LTE1MS4xNjUsMTUxLjQyMWMtLjYwNS0xLjk4OS0xLjYxNC0zLjA3OS0zLjUxOC00Ljk4MkwxMjEuODAzLDIzOC4xMjZsLTQuNzQtNC42ODgtNDguOTgxLTQ4LjgyM2MtMy4wNDEtMy4wMzEtNS40OC01LjYzMi04LjYxNS04LjU3NGwtMTQuODk2LTEzLjQ3YzQuMzY5LTEyLjQ2NywxMC4wMTUtMjUuNjA3LDE5LjgzNi0zNS40NDFsNDIuMDU1LTQyLjExMmMxLjkwMiw2LjAyMS0zLjMzMiw4LjYxLTcuMjU5LDExLjk3My0yLjgzLDIuNDI0LTQuODIzLDUuNjQ5LTguNDg5LDcuNDQ2LTEuNDA0LDMuMDE2LTEuNTUzLDcuNTM3LTEuODkzLDExLjIwMSwzLjY4OS43MzUsNC45OTMsMi42MzEsNi43Nyw1LjMzLjc3MSwxLjE3MSwyLjU2MSwyLjIyMSwyLjg2MiwzLjIyLDEuNDcxLDQuODg2LTExLjc0NiwzLjczLTEzLjM4OSw3LjQzNi0xLjQ2NiwzLjMwOCwxLjIxNiw2LjkyOC0xLjg3Myw4LjcwOS0uODI4LjQ3Ny0zLjExNi0uNzU3LTQuMDEtLjM1LTIuMTQyLDEuNjA0LTUuMDM5LDEuODg1LTcuMzEyLDIuNjg1LTIuMTk1Ljc3Mi0xLjc0LDQuODA0LTEuMDQ1LDcuMTc4LTMuNDk1LjkxNy04LjAzNiwyLjM3Mi04LjY5Nyw1LjkyLS4xODEuOTczLDIuMDMyLDIuNTgyLDEuOTI4LDMuNTIzLS4yOTgsMi42ODktMy4yMDUsNC41NzgtMi41NzIsNy40NS4xODguODU0LDIuMjk0LDEuNDQ1LDIuOCwyLjU5LDEuMTM2LDIuNTczLDMuMDA0LDcuMjc2LDYuMzc2LDYuOTE1LDguMjEtMy44MTgsMS44NzMsOS4xMDIsMTQuMTY4LDEwLjUxNyw2LjAzOC42OTUsOC4zMDksNi41NTEsOC43OTQsMTIuMTQ5LDIuMjgyLjA3OSw2Ljc1Ni42MTUsNy4zMzcsMi4zNDUsMS41MzQsNC41NjgsMy40ODgsNS4zLDcuOTcyLDUuODM1LDUuMjE0LjYyMiwxMC4yMTgsMi42NzEsMTUuNjIzLDEuNTQzLS4yMjQsOC4yNzcsNy45NzUsNS4wMjIsMTIuMTc5LDEwLjQ4Ny0uNDc1LDEuOTkxLTEuNjA3LDQuODg0LDEuNTQxLDYuNDQ0LS45OTksMS4xMzMtMS43NjMsMy44MTMtMS4xMDEsNC42NzQsMi43MiwxLjg3NCwzLjU5OSwzLjg3MSwyLjUxMyw3LjczNiwyLjc3Ny0uMzksNS44Mi0uNDExLDcuNTUzLTIuMjQ1LjI3My0xLjEzMy4xODQtMy44NDksMS4yOTEtNC4zMjIsMS43OS0uNzY1LDYuNjQ0LDEuNjgzLDcuNTMzLDMuODM4LDEuODg0LDQuNTcxLTcuMTksMS4wMzEtOS4wMDYsNi40NzQtLjUxLDEuNTI3LjQ2LDMuNjE3LDEuNDY3LDMuOTA1LDEuMTI1LjMyMiwyLjQ3Mi0uMDk4LDMuNDkzLS45NjIsMy41MzMtMi45OSw3LjA3NywxLjA5NCw4Ljk1OC0uNDQxLDIuNzE0LTIuMjE1LTEuNjk1LTkuMjYxLDUuOTExLTExLjU4Nyw1Ljc1OC0xLjc2MSwyLjMwNi02LjMzMSw3LjExMy05LjAzMi0zLjUxMi0yLjE2Ni01Ljk3OS0uNDY5LTkuMjIzLDEuMDZsLTIuNTk1LTUuMzUxYzMuMjMtMy4yNzQsOC41MjUtMi45NDcsMTEuODE4LDEuMzA0LDIuODQ0LTEuNDQxLDUuNjc0LTEuNzk1LDguMTgyLTMuODAzLDEuMDgxLS44NjYuNDM1LTQuNDkxLDEuMDk3LTYuMjI2LDEuMDY0LTIuNzg1LDYuMjE0LTYuMzM0LDguODY4LTQuNDIzLDEuMTExLjgyNi44ODQsMy42ODYsMS43OSw0LjA2NS43MzguMzA4LDIuOTc4LjQ0MywzLjcxNS44ODcsMS4zNCwyLjE3NS0uMDgzLDQuMDg0LTIuMjUxLDUuNTU1LTIuODI0LDEuOTE2LTYuMTA4LTMuMDM1LTE0LjExNiw4LjMwNSwyLjI2Niw3LjQ1My0yLjAyLDkuMjAzLTEuMzkyLDExLjAyNS4xOC41MjQsMS45MDYuNDQzLDIuMDUxLjA5NGwuNzUxLTEuODEzYzUuODg0LTMuNTI0LDEuNzkxLTcuMzMxLDQuMjMxLTEwLjEwNCwyLjM0MS0yLjY2LDkuNDg3LTEuMDY3LDEzLjEzLTcuMTM4LDEuNzgtMi45NjYsMi43My03LjQ0LDEuMjYzLTEwLjI1NC0xLjQ1Ny4wMS0zLjgxMS4wOTgtNC43Mi0uMTQtLjY0Mi0uMTY4LTEuMjQyLTIuMjc5LS4zNTUtMy4wMjMsMS4xMjUtLjk0MywzLjUyNS0xLjMyLDQuNTU0LTMuMTI5LDIuMzM5LDEuNzksMi42MjMsNC41NjQsMy44NTQsNi4yNDEsMS45NDgsMi42NTQsMy44NDctLjUyOCw1LjE0OC0xLjAxLDMuMTU3LTEuMTcxLDYuNjE5LTMuMTQ1LDYuMTkyLTYuNzE5LS44My0uMTg1LTMuNDM1LTEuNDQ0LTMuMTA0LTIuMzQ1LDEuNDE0LTIuMDc1LDQuNTM3LTIuMzQsNi45NDItMS45NjRsLjM3NCw1LjYwOGMyLjc4Ny0xLjcyNyw1LjUyLTMuMzMzLDcuNjYxLTUuNTA4LDEuMzIzLTEuMzQ0LS4wNzQtMy42OTgtMS4xNDEtMy40MjYtLjY3My4xNzEtMS44NjksMS4zMTctMi42NzMsMS40NDUtMi41MjUuNC0yLjYwMS0xLjk3My0yLjIzLTMuNTU2LjI0OS0xLjA2Mi45MzItMy4xNzMsMi45ODEtMi4yODQuOTIxLjQsMi4yNTksMi4wNDIsMy4zOTksMS41MjMsNC41OTctMi4wOTQsNi43MTQtLjE0Miw3Ljk1Mi0zLjI2Mi0uMTA3LS42MTItLjcwOC0xLjI2LTEuMTI3LTEuMzItLjUyMi4wMzMtLjk0Ni0uNjc2LS42NTYtLjkxMS42NTctLjUzNC45MzMtLjEzNywxLjEzNi4wMDkuMjQ3LjE3OS42MzEuNzg2LjU3LDEuMjY0bC41MDYuNDI5YzIuMDA2LTEuNjQsNC42MDQtMi44NDMsNS44NzMtNi40OTQtMy4wMjItLjc0Mi02LjExOS4yOTUtNy44NCwzLjc3NS0uNjQ5LS45NzctMS4xOTItMi4zNS0xLjI0LTMuNjU4LS4wNzItMS45NTMsNS4zOTYtNi4xODIsMTAuMjQ2LTMuNTkyLDEuMTcyLTQuNDMyLDQuODQ2LTQuNTk1LDguMjk5LTMuODVsLTMuNjk5LDQuMDAzYy0xLjI1MywxLjM1Ni0yLjI0MywyLjQ1OC0yLjMwNSwzLjg3NmwtMzEuMTk5LDMxLjU1Yy0yLjM2OSwyLjM5Ni01LjM2NiwyLjk2Ni02Ljk5Nyw2LjI4Mi0yLjkyNyw1Ljk0Ny05LjQ4Niw5LjIyMi0xNC4wOTMsMTMuNjg0LTQuMTQxLDQuMDExLTYuMjg1LDkuMjkzLTExLjM4NywxMi4yODYtMi40MTUtLjAxMy0zLjM2MywxLjY5MS00Ljg1NywzLjYyOS0xLjE4LDEuNTMxLTMuNDQzLDIuNDMzLTMuMDg1LDQuMzA2LTIuMywyLjI5OC00Ljk4Myw0LjUzLTcuMTUyLDYuOTc0LTIuNjM4LDEuMjYzLTYuNjcyLDMuODEyLTcuMDM0LDcuMzA2LS4wNTYsMi40MjEsNC4xNzksNS4zNzksNS45MTYsNS41MjlsMTYuNDI2LDE2LjA2Nyw3MC45MTItNzEuMTg1LDE1LjYwMi0xNS43MjItNTIuODE3LDkyLjIzMWMtMy40NTgsNi02LjQwNywxMS4zMzMtMTAuNTM5LDE3LjQ3OGwyMi4yOSwyMi4xODMsNzAuNjUxLTQwLjU2OGMyLjQwMi0xLjM3OSw1LjQ4LTEuNTYxLDguMTMzLTMuMjM3bDExLjE3My03LjA1NmMxLjI4NS0uODEyLDIuOTg0LDEuMTkzLDIuMjc1LDIuMTA3bC0xNy44NzgsMTguMzU2Yy0xLjAwNCwxLjAzMS0yLjA1OSwyLjI3Ni0xLjg1Niw0LjA0bC00NS42NzMsNDYuMzI5Yy0xLjI4NiwxLjMwNS0yLjk0MSwxLjk3Ny0yLjc5MSwzLjg0NS4yNTgsMy4yMTQsMTQuMDI2LDEyLjczMSwyMC4xNTUsMjEuMjA3bDEyMi45MjktMTIzLjA4NS0zNC4wOTktMzQuMjUtMTkuMzI2LDEyLjI4NC01Ny4wNCwzMy44MDMtMjguNjU2LDE2LjY3Niw0OC42ODEtODYuMzI1LDExLjg4OC0yMC43MDYtMzIuNzctMzIuNzkxLTIwLjUyNCwxOS40MzljLjAyOC0uNzAxLS43MDItLjcyMS0xLjI2OC0uMjU2bC0xLjgzLDEuNTA1Yy0uMjg0LTIuMzc1LTIuNTczLTIuNDI0LTQuNTEzLTEuODkzLTMuMjA0Ljg3Ni0yLjU1LDUuMTg2LTQuMjA0LDUuNzc5LS43MTkuMjU4LTMuMzYzLTEuMzMtOC4zNDYuMzQ0LTIuMjUtMi43NjgtNC40NjgtNC4wNzQtNy41MjYtNi4xMjhsNC44OC03LjUzNmMzLjcyOC0xLjY3MSw1LjkyNS00LjAyMiw2LjcyLTguMzY2LDMuMjU0LS40MSw2LjI1NC0uNzE5LDkuNTI3LjM1NC0uNDU5LDIuNTM2LTEuNDQ5LDMuNTE1LTIuMjQxLDUuMTA0LDIuMDY4LjE1OCwzLjQ3OC4zOTcsNC4yMTcsMS4wNzYuNTczLjUyOC0uMDg1LDIuNDI0LS40NSwzLjI5NC0uNjcxLDEuNTk3LjUzNCwyLjEyNiwxLjMzNCwyLjA4MSwzLjA3Ni0uMTc0LDMuNDgyLTMuNzE4LDcuNDMtNC4yMDEsMy4yNTgtLjM5OSw1LjcwNS0yLjM5Myw2LjIxNC02LjA0NWwtNi45MjQuMTkxYy0uOTkzLTIuNzc3LDIuNjE4LTMuMzA2LDMuMDc4LTQuNDQ1LDEuOTc2LTYuOTU5LDIuNTI3LTEwLjg5OC0yLjEyMi0xNi41NTYtMi4yMTgsMi40NTMtMy4zNDIsMy45MDUtNi44NDIsNC41OTQsMS41ODUtNy41MzgtMi44NzMtMTEuNTQ4LDIuNDc5LTE1LjUwNmwtNy44MDktNS41MWMtLjY4My00LjcwMi0zLjM3NS04LjUzMy03LjMxLTExLjM2My0yLjY0MS0xLjg5OS0zLjk2NS00Ljg5LTYuMDY3LTYuODUxLTUuMTYtNC44MTYtMTQuNjMzLTEzLjIyOC0xNS4yMTUtMTYuMDg4LS4yMjctMS4xMTYtMy4zODUtMS43NDgtNC4wNDYtMi42MzgtNS42MTItNy41NTYtMTAuMzA3LTkuMjY2LTkuMzUxLTEzLjU3NWw4LjMyOSw2Ljc2OSwxNzUuNzA2LDE3NS43ODIsNi41MTksNi44MzUsMjQuNCwyNC40MDNjMy4zNjUsMy4zNjUsNS43NDYsNi42NTUsOS42NDksOS42MTIsMy4wNjksMi4zMjYsNi41Niw1Ljc1OCw4Ljc2Nyw4LjgyOSwxLjkxNSwyLjY2NiwzLjY3OSwzLjMwMiw1Ljk1NSw1LjU3OGwxNTQuMjI1LDE1NC4yMzgsMjEuODkxLTIyLjE0Yy00LjM4NS01Ljk5LTkuMjk4LTEwLjA4OC0xNC43ODUtMTQuOTk1TDI3Ny4zODQsNzcuNTY0Yy0xLjk4Ni0xLjk4Ni00LjMwMS0yLjI0Mi01LjA2NS00LjcyNVpNMjgzLjg2MiwxNDEuNDA3YzQuMDY3LTEuOTc5LDMuMTgzLTQuNTAxLDIuNzItNi43MzQtLjMwNS0xLjQ3My05LjI2MS04LjIwMS0xMC43MDEtNC43NTIsMS4zODgsNC4wNTEsNS4xNSw3LjU1Miw3Ljk4MSwxMS40ODZaTTI4MC4wMDksMTQxLjQxOGMtMS45OS0xLjU1Ni0zLjA0Ny0yLjM3My01LjMyNC0zLjAwNC0xLjY2NSwyLjQxNy0uMTE0LDQuNzk3LDIuMzk0LDYuMzM1LDEuMDQ1LTEuMDMxLDIuMTUxLTEuNjA4LDIuOTMtMy4zMzFaTTMwNC43MzUsMTU3Ljc2OWMtLjY0NS0xLjM1Mi0uNDY0LTMuMDI5LS4wNzItNC43NzRsLTMuOTU4LTMuMjJjLTEuMzQzLTEuMDkzLTMuMTE5LTUuNzY2LTUuMzk3LTQuNjk0LTIuNDk4LDEuMTc0LTEuMDc2LDUuMDk0LjQ2OSw2LjE4NCwxLjkzNCwxLjM2NCwzLjQ3OSwxLjQ5Niw2LjQ0MiwyLjEzNC0xLjI1MywxLjA1Mi0yLjU0OSwyLjU3OC0xLjc5MSwzLjI1Ny45MTYuODIsMi4wMjEsMS40NzEsMy4wNTEsMS45NDZsMS4yNTctLjgzMlpNMjUzLjk2NywxNTQuNzI5Yy4xMzQtMS41NjQtMi41MDQtMS44OTEtMi45MjEtLjg3Ni0xLjA5Myw1LjQxOS04LjE4Myw1Ljc1Ni01LjY5MSw4LjkwNSwyLjM4OSwzLjAxOCw4LjIwNC0zLjI2Myw4LjYxMi04LjAzWk0zMDQuNzY5LDE1OC4wNTFsLS45NzUsMS4xNmMtLjUzOSwxLjI0MS43MDUsMS41NDcsMS4zNywxLjA3Ni4zMjYtLjIzMSwxLjA3NS0uNDUzLDEuMDY1LTEuMDUtLjAwNy0uNDExLTEuMTM2LTEuMTAzLTEuNDYtMS4xODZaTTE3MS4xNTIsMjM5LjkxbDYuNTktMy42OTFjLjc5OS0xLjA1MS0xLjQzOS0zLjEzMi0yLjU1MS0zLjM2OS0zLjc0OC0uNzk5LTQuNjI1LDMuNDU4LTkuNTQ1LDcuMDQxbC41ODEsOC40ODNjLjA4NywxLjI2NiwyLjU1Ny43MTIsMi45NDYuMDI1LDEuNjU2LTIuOTI2LS4xNjEtNy4yOSwxLjk3OS04LjQ4OVpNMzE4LjM5NSw0MjIuNTIyYy0uMjUsMy40NjUsMy4wOTYsNC45OTgsNS4zNjYsNy4zMzdsMTAuMjYzLDEwLjU3NWMyLjA1MSwyLjExMywzLjY1NSwzLjQ4Niw1LjU3OSw1LjQyOWwxMS40NSwxMS41NTdjMS42OTIsMS43MDgsMi41MTIsMi40MjIsNC4xNTIsNC4wNjZsMTEuODgyLDExLjkwOGMxLjc1NiwxLjc2LDIuNjczLDIuODU0LDQuNjI3LDQuNjU4bDguNzU1LDguMDg0LDQuODMzLDYuMDExYzIuMDc1LDIuNTgxLDUuNjg3LDMuNDgxLDcuNTY0LDYuNzE3LjcyNSwxLjI1LDMuODE0LDIuODIsNC40NDksMS40ODcsMS44NzMtMy45MzIsNC4wNjctNi41NTcsOC4yMzgtOC4yNzgsMS40NjgtLjYwNiwyLjE5OS0zLjMzMywzLjI5NS00LjQybDYuMDc3LTYuMDI3YzEuNDc5LTEuNDY3LDQuNzcxLTIuNDA3LDMuMjY0LTUuNTA5bC01LjI4Ni01LjM0Yy0xLjIxOS0xLjIzMi0yLjA1Ny0yLjA1Mi0zLjYyNC0yLjAzbC03LjQxNi03LjEyNiw2LjYyMi0xMS42MTksNjMuMjIzLTExMi40MDdjLjg1OS0xLjUyNywzLjc0OC0zLjY2NCwxLjkyNS01LjUzNGwtMjAuOTMtMjEuNDc5LTExLjQ4OCw2LjUzNi0xMTguMzg5LDY1LjUzOS0xNi4zOTctMTYuMjUxLTIxLjkzOCwyMS42OTgsMTAuNTMzLDEwLjU1OCwyMy4zNywyMy44NjVaIiBmaWxsPSIjMmU4NGNkIi8+CiAgPHBhdGggZD0iTTQ5Ni4wOTYsMjU1LjA5bDQ2LjE4NCw0Ni45OTksMS42MzcsMS42ODYsNDYuMjM2LDQ2LjY2N2MtLjg0MS0uMTU0LTIuMDMzLjI2Ni0yLjE1My44OTRsLS41NjEsMi45MzctNC41NDQsNC42MDVjLS45Ny0uNTYyLTEuMTAyLTIuMDI4LTEuMTg5LTIuNTQ3LS4xNTgtLjk0Mi0xLjcxMi0uNzk4LTEuODc0LS4zMDhsLS45NjUsMi45MjRjLTMuODE3LDEuOTE2LTExLjI3NywxLjI5LTE1LjAyNi0xLjk5NS0xLjg0OS0xLjYyLTQuNjg0LTMuNDAyLTUuNzUzLTUuMjA2LTIuODM2LTQuNzg3LTYuNDc4LTcuNDI5LTEwLjItMTAuOTQ0LTQuNDE4LTQuMTcyLTkuMzc3LTExLjI5Ny0xNi45MjEtMTMuMjM1LS4wNTYtMy42MTYtLjc0NS02LjQ0NS00LjAzNy03LjgzMS0zLjM1MS0xLjQxLTQuMDQ1LTUuMzcxLTYuMzE4LTcuNTIzLTMuNzIyLTMuNTI0LTguNjQtNi41NjItMTEuNC0xMC41ODgtMi41MDQtMy42NTQtNS4zNDItMy43NjMtOC43NDQtNi4xMTYtMS42MzQtMS4xMzEtNC4wNDctMy44MjktNS44MTktNS40MTZsLTEwLjcyMi05LjZjLTEuNzQ0LTEuNTYyLTIuMjkyLTQuNDI5LTUuMjg2LTUuNjAzLTUuMDE1LTEuOTY3LTcuMDk2LTcuMTQ1LTcuNzY4LTEyLjE2Mi0yLjE0LTEuNDc3LTQuNjAyLTMuNjg0LTYuMTY3LTUuNzE4LTMuMzcyLTQuMzgzLTguNzAyLTUuMzc3LTEyLjgzNC04LjM3NS0zLjY1Ny0yLjY1My04LjI0LTcuNjE4LTkuOTM3LTExLjY3NC0xLjYzNy0zLjkxMy0xLjMzMS02LjMyMy01LjI0OC05LjM1NS0xLjk1MS0xLjUxMS0yLjQwNy03LjA2Ni01LjE2Mi04LjI2Ni0yLjI2My0uOTg2LTQuNzY3LS44My02LjYwNy0yLjc5LTUuMTQuMjcyLTguOTYxLTIuODY2LTkuOTc4LTcuOTQtNi4yMjYtMi41MTgtMTEuMjQtNi41MTYtMTQuNTEyLTEyLjM3Ny0zLjI0NC0xLjgxMy0zLjg5Ni01LjUxNC02LjMyNi03LjgzMWwtNi42NzUtNi4zNjVjLTIuMDUxLTEuOTU1LTQuNzU3LTYuMTE3LTcuMTEzLTcuMTIyLTMuNDQ0LTEuNDY4LTMuMzI4LTMuMTA3LTUuMzcxLTUuMzY0LTUuNjk1LTYuMjkxLTEyLjg3LTExLjk5Ni0xNC45NzItMjAuNjUzLTIuMDQ2LS42NC0zLjcxNi0zLjI5NS00Ljk0My00LjItMTAuMDc2LTMuMjI0LTE2LjQ2NS0xMC40LTIzLjUzNi0xNy40NzJsLTE1LjU0OS0xNS41NTFjLTEuOTc0LTEuOTc1LTMuNDIzLTMuNzIzLTUuMjIyLTUuNDY0LTIuOTM0LTIuODM5LTUuODY3LTQuNjA4LTguMzMyLTguMDYzLTMuOTc5LTUuNTc3LTkuNDQxLTEyLjczMy0xMy42MjUtMTUuNjk2bC0xMC4yNi03LjI2NWMtMi4zNzktMS42ODUtMy41NTktMi42NjItNi4xODEtMi4zNS0yLjQwNy4yODctNC40ODMtMi41OTQtNi43OTItMy42NzVsLTE4LjQ1OC04LjY0Ni0uMzktMS4zMDJjLS4xNDQtLjQ4MS0uNjU1LS42MDItLjkzNC0uMzQ1LS41Mi40NzktLjc0NS45Mi0uOTAyLDEuMjc5LTIuMjM4LS42MzUtNC41MzgtMS4zOTItNi44OTctMS4yOC40MDMtMS40NDktLjExNC0yLjI1Ni0xLjQ5OS0yLjMxOS0xLjEzNS0uMDUxLTIuMjk0LS4xMTktMi41NTMsMS4zOThsLTE5LjAwNi0uNDMyYy0xLjIxNS0uMDI4LTEuNzQ3LjU1Ni0xLjkwNiwxLjI3NS0uOTU3LDQuMzA5LDMuNzM5LDYuMDE5LDkuMzUxLDEzLjU3NS42NjEuODksMy44MTksMS41MjIsNC4wNDYsMi42MzguNTgzLDIuODYsMTAuMDU1LDExLjI3MiwxNS4yMTUsMTYuMDg4LDIuMTAyLDEuOTYxLDMuNDI2LDQuOTUyLDYuMDY3LDYuODUxLDMuOTM1LDIuODMsNi42MjcsNi42NjEsNy4zMSwxMS4zNjNsNy44MDksNS41MWMtNS4zNTIsMy45NTgtLjg5NCw3Ljk2OC0yLjQ3OSwxNS41MDYsMy41LS42ODgsNC42MjUtMi4xNCw2Ljg0Mi00LjU5NCw0LjY0OSw1LjY1OCw0LjA5OCw5LjU5NywyLjEyMiwxNi41NTYtLjQ2LDEuMTM5LTQuMDcxLDEuNjY4LTMuMDc4LDQuNDQ1bDYuOTI0LS4xOTFjLS41MDksMy42NTItMi45NTYsNS42NDYtNi4yMTQsNi4wNDUtMy45NDguNDgzLTQuMzU0LDQuMDI4LTcuNDMsNC4yMDEtLjguMDQ1LTIuMDA1LS40ODQtMS4zMzQtMi4wODEuMzY2LS44NzEsMS4wMjMtMi43NjcuNDUtMy4yOTQtLjczOC0uNjgtMi4xNDktLjkxOC00LjIxNy0xLjA3Ni43OTEtMS41ODksMS43ODItMi41NjgsMi4yNDEtNS4xMDQtMy4yNzMtMS4wNzMtNi4yNzMtLjc2NC05LjUyNy0uMzU0LS43OTQsNC4zNDMtMi45OTIsNi42OTUtNi43Miw4LjM2NmwtNC44OCw3LjUzNmMzLjA1OCwyLjA1NCw1LjI3NiwzLjM2LDcuNTI2LDYuMTI4LDQuOTgzLTEuNjc0LDcuNjI3LS4wODcsOC4zNDYtLjM0NCwxLjY1NC0uNTkzLDEuMDAxLTQuOTAzLDQuMjA0LTUuNzc5LDEuOTQtLjUzMSw0LjIyOS0uNDgyLDQuNTEzLDEuODkzbC0zLjE5OCwyLjg2MWMtMi4wODIsMS44NjMtMy4yOTksMy41NTEtNC45NTgsNS4zNDYtMy40NTMtLjc0NS03LjEyNy0uNTgzLTguMjk5LDMuODUtNC44NS0yLjU5LTEwLjMxNywxLjYzOC0xMC4yNDYsMy41OTIuMDQ4LDEuMzA4LjU5MSwyLjY4MSwxLjI0LDMuNjU4LDEuNzIxLTMuNDgsNC44MTktNC41MTcsNy44NC0zLjc3NS0xLjI2OSwzLjY1LTMuODY3LDQuODUzLTUuODczLDYuNDk0LS4xNzUuMTQzLS4zNDMuMzEyLS40MjkuNTI5LTEuMjM4LDMuMTItMy4zNTUsMS4xNjktNy45NTIsMy4yNjItMS4xNC41MTktMi40NzctMS4xMjMtMy4zOTktMS41MjMtMi4wNDktLjg4OC0yLjczMiwxLjIyMy0yLjk4MSwyLjI4NC0uMzcxLDEuNTgzLS4yOTUsMy45NTYsMi4yMywzLjU1Ni44MDUtLjEyNywyLTEuMjczLDIuNjczLTEuNDQ1LDEuMDY4LS4yNzIsMi40NjQsMi4wODIsMS4xNDEsMy40MjYtMi4xNDEsMi4xNzUtNC44NzQsMy43ODEtNy42NjEsNS41MDhsLS4zNzQtNS42MDhjLTIuNDA1LS4zNzYtNS41MjgtLjExLTYuOTQyLDEuOTY0LS4zMzEuOTAxLDIuMjczLDIuMTYsMy4xMDQsMi4zNDUuNDI3LDMuNTczLTMuMDM1LDUuNTQ4LTYuMTkyLDYuNzE5LTEuMy40ODItMy4xOTksMy42NjQtNS4xNDgsMS4wMS0xLjIzMi0xLjY3OC0xLjUxNi00LjQ1Mi0zLjg1NC02LjI0MS0xLjAyOCwxLjgwOS0zLjQyOCwyLjE4Ni00LjU1NCwzLjEyOS0uODg3Ljc0My0uMjg3LDIuODU0LjM1NSwzLjAyMy45MDkuMjM5LDMuMjYzLjE1LDQuNzIuMTQsMS40NjcsMi44MTQuNTE3LDcuMjg4LTEuMjYzLDEwLjI1NC0zLjY0Myw2LjA3MS0xMC43ODgsNC40NzctMTMuMTMsNy4xMzgtMi40NDEsMi43NzMsMS42NTMsNi41OC00LjIzMSwxMC4xMDRsLS43NTEsMS44MTNjLS4xNDUuMzQ5LTEuODcuNDMtMi4wNTEtLjA5NC0uNjI3LTEuODIyLDMuNjU4LTMuNTcxLDEuMzkyLTExLjAyNSw4LjAwOC0xMS4zMzksMTEuMjkyLTYuMzg4LDE0LjExNi04LjMwNSwyLjE2Ny0xLjQ3MSwzLjU5LTMuMzgsMi4yNTEtNS41NTUtLjczNy0uNDQ0LTIuOTc3LS41NzktMy43MTUtLjg4Ny0uOTA2LS4zNzgtLjY3OC0zLjIzOC0xLjc5LTQuMDY1LTIuNjU0LTEuOTExLTcuODA1LDEuNjM4LTguODY4LDQuNDIzLS42NjMsMS43MzUtLjAxNiw1LjM2MS0xLjA5Nyw2LjIyNi0yLjUwOCwyLjAwOC01LjMzOCwyLjM2Mi04LjE4MiwzLjgwMy0zLjI5My00LjI1LTguNTg4LTQuNTc4LTExLjgxOC0xLjMwNGwyLjU5NSw1LjM1MWMzLjI0NC0xLjUyOSw1LjcxMS0zLjIyNiw5LjIyMy0xLjA2LTQuODA2LDIuNzAxLTEuMzU1LDcuMjcxLTcuMTEzLDkuMDMyLTcuNjA1LDIuMzI2LTMuMTk2LDkuMzcyLTUuOTExLDExLjU4Ny0xLjg4MSwxLjUzNS01LjQyNS0yLjU1LTguOTU4LjQ0MS0xLjAyMS44NjQtMi4zNjgsMS4yODUtMy40OTMuOTYyLTEuMDA3LS4yODgtMS45NzctMi4zNzgtMS40NjctMy45MDUsMS44MTctNS40NDMsMTAuODkxLTEuOTAzLDkuMDA2LTYuNDc0LS44ODgtMi4xNTUtNS43NDItNC42MDMtNy41MzMtMy44MzgtMS4xMDguNDczLTEuMDE4LDMuMTktMS4yOTEsNC4zMjItMS43MzMsMS44MzUtNC43NzYsMS44NTUtNy41NTMsMi4yNDUsMS4wODYtMy44NjUuMjA3LTUuODYxLTIuNTEzLTcuNzM2LS42NjItLjg2MS4xMDItMy41NDEsMS4xMDEtNC42NzQtMy4xNDktMS41Ni0yLjAxNi00LjQ1My0xLjU0MS02LjQ0NC00LjIwNC01LjQ2NS0xMi40MDMtMi4yMS0xMi4xNzktMTAuNDg3LTUuNDA1LDEuMTI4LTEwLjQwOS0uOTIxLTE1LjYyMy0xLjU0My00LjQ4NC0uNTM1LTYuNDM5LTEuMjY4LTcuOTcyLTUuODM1LS41ODEtMS43MjktNS4wNTUtMi4yNjYtNy4zMzctMi4zNDUtLjQ4NS01LjU5OC0yLjc1Ni0xMS40NTQtOC43OTQtMTIuMTQ5LTEyLjI5NS0xLjQxNS01Ljk1OC0xNC4zMzUtMTQuMTY4LTEwLjUxNy0zLjM3Mi4zNjEtNS4yMzktNC4zNDItNi4zNzYtNi45MTUtLjUwNi0xLjE0NS0yLjYxMi0xLjczNi0yLjgtMi41OS0uNjMyLTIuODcyLDIuMjc1LTQuNzYxLDIuNTcyLTcuNDUuMTA0LS45NC0yLjEwOS0yLjU0OS0xLjkyOC0zLjUyMy42NjEtMy41NDgsNS4yMDItNS4wMDMsOC42OTctNS45Mi0uNjk1LTIuMzc0LTEuMTUtNi40MDUsMS4wNDUtNy4xNzgsMi4yNzMtLjgsNS4xNy0xLjA4LDcuMzEyLTIuNjg1Ljg5NS0uNDA3LDMuMTgyLjgyOCw0LjAxLjM1LDMuMDg5LTEuNzgxLjQwNi01LjQwMSwxLjg3My04LjcwOSwxLjY0My0zLjcwNiwxNC44Ni0yLjU1LDEzLjM4OS03LjQzNi0uMzAxLS45OTktMi4wOS0yLjA0OS0yLjg2Mi0zLjIyLTEuNzc3LTIuNjk5LTMuMDgtNC41OTUtNi43Ny01LjMzLjM0LTMuNjY0LjQ4OS04LjE4NSwxLjg5My0xMS4yMDEsMy42NjYtMS43OTcsNS42NTktNS4wMjIsOC40ODktNy40NDYsMy45MjgtMy4zNjQsOS4xNjEtNS45NTIsNy4yNTktMTEuOTczLDIuMDEtMi4wMTMsNC43ODktNi4zNzEsNy4zNTgtNi44NzUsMy43MzYtLjA2MSwyLjc0NS0yLjg1OCw0LjM0NS00LjQ5M2wzMS4wMzktMzEuNzAzYzEuOTU0LTEuOTk2LDQuNTkyLTIuOTk2LDUuODQ5LTUuMTgzLDEuMzA2LjAzNSwzLjgyLjI2NSw1LjE4Ni0uODI4LDMuMzU2LTIuNjg2LDcuNTI0LTMuODQ0LDEwLjgzMi02LjIxLDQuNTE2LTMuMjMsOC44MDEtNC43NTIsMTQuMTk1LTUuOTUzLDMuMjgtLjczLDcuMDQ3LTIuOTkxLDEwLjYyNi0yLjkwNCw1LjA2OC4xMjMsMTUuNTc5LTQuMjg2LDI5LjkwNy0xLjc5LDkuMjUyLDEuNjEyLDE4LjMwNSwyLjI2NCwyNS43MDMsNi4xNjMsMi4yNDcsMS4xODQsMy4xMzQsMS45NDksNS44MSwzLjE5NmwxMi4wNTksNS42MThjMS44OTcuODg0LDIuNDkyLDIuNzk5LDMuMzA5LDMuNjQ3LDMuNzA5LDEuNzY0LDYuODE3LDMuNjQ1LDguODY3LDcuNTE4bDQuMjI2LDMuNTIyYzEuMzgxLDMuNjU0LDQuMDE0LDUuNjk5LDcuNzk4LDYuMzI0LDMuMjcxLDUuMDEyLDcuMTY0LDEwLjUyMSwxMi4zNDcsMTMuNDM1LDMuMzk4LDEuOTEsNC40MjMsNC42MzEsNi45MTIsNy4wNzNsMTMuNjAzLDEzLjM0NGMyLjg3LDIuODE1LDQuMzU0LDQuNTI3LDcuMTc3LDcuMTQ0LDkuNzc5LDkuMDYzLDE1LjAzMiwxNy45MTcsMjUuMDQyLDI0LjgwOWw0LjI0Niw1LjAwNWMyLjYxMywzLjA4LDYuOTEyLDYuMTU2LDkuNjA3LDkuMTMsNS42NDYsNi4yMzIsMTAuNTMzLDExLjg3LDE3LjA3MywxNy4xMjQsMi43MTcsMi4xODMsNC4xMDYsNS41MDksNy40NjEsNy42MDMsMi4yMjQsMS4zODgsMy43MDcsNC45MjYsNi42LDYuMjQ4LDIuMzA2LDEuMDU0LDMuODcsMy4xOCwyLjQ4MSw2LjM5MSw1LjQ1LTEuMTc0LDcuMjQ0LDMuNzYyLDEwLjM2OSw2LjYsMy42NDgsMy4zMTIsNS45MDcsNi42MzQsOS40MjcsOS45MDZsNy4yODEsNi43NjgsNy44MjksNy45NjJjMy4xOTMsMy4yNDcsNy4yODMsNS41MjQsOC4xNTIsMTAuNTE2LDMuMzk0LS4wNTEsNS4zMjEsMy4yNDgsNy4yNTIsNC44NywzLjU2NiwyLjk5Niw1Ljk1NCw1LjkzNiw5LjA5NCw5LjEyNSwyLjM3MywyLjQxLDUuOTA5LDMuODI2LDUuNzk1LDguMDg0LDQuMDUyLjA1LDcuOTEsNS42MzUsOS4zMjcsMTAuMjgzLDEuNzcxLS43MzMsMy4wOTYtLjUxNCwzLjkzNi4wMjMuOTEyLjU4NCwxLjQ4OCwxLjYzOCwxLjc1MywyLjg1MiwyLjEzLDMuODYsNS44OTMsNS43NTEsOS43NTcsNS43MjVaTTEwNi40ODgsMTA1LjIyMmMuNDE5LS4yODEsMS42Mi0uNjYsMS42NzktMS4xMjguMDg2LS42ODctLjQwNy0xLjM3Mi0uODA0LTEuNjItLjUzNC0uMzMzLTEuNDIyLS41MzItMi4yNjUuMjY3LTEuMDQ2Ljk5MS0xLjA3OCwxLjQyNi0uNjczLDIuMTgyLjQxMi43NjksMS4yNTkuODM5LDIuMDY0LjI5OVpNMjY1LjYzNywxMzcuNjA3Yy0xLjIyNi0yLjUxOC00LjItLjE5Ni00Ljg3LDEuMjkyLS43OTUsMS43NjUtMi4zNjgsMi43ODUtMS4wMzcsNS43NTYsMi41NzkuNTI4LDcuNjM1LTMuNTAyLDUuOTA4LTcuMDQ4Wk0yMzMuMTA0LDE2OC4yMjdjLTIuMDQtMS4zMzEtNC44NTksMy44NDMtNS4wMzgsNi42Ny0uMDYzLjk4OSwyLjkzLDEuMzEzLDMuODE1LjI2NywyLjI5MS0yLjcwNywzLjA1Ni01Ljc0LDEuMjIyLTYuOTM3Wk0yNDEuNjg4LDE2OC4zMzJsLTQuMTU5LS4wOTJjLjAzMiwyLjY0MiwxLjU5NiwyLjUwNCwyLjg4NiwyLjU2NywxLjQwNC4wNjksMi4wOTktMi4xMjQsMS4yNzMtMi40NzZaTTIyMy4wNjYsMTcyLjY1OWMwLS42MTUtLjQ5OS0xLjExMy0xLjExMy0xLjExM3MtMS4xMTMuNDk5LTEuMTEzLDEuMTEzLjQ5OSwxLjExMywxLjExMywxLjExMywxLjExMy0uNDk5LDEuMTEzLTEuMTEzWk0yMzYuMDY3LDE4NC4yNzNjLjA2MS0uNDc5LS4zMjMtMS4wODUtLjU3LTEuMjY0LS4yMDMtLjE0Ny0uNDc5LS41NDMtMS4xMzYtLjAwOS0uMjkuMjM1LjEzNS45NDQuNjU2LjkxMWwxLjA1LjM2MlpNMjE3LjM3MywxODUuMjczYy0xLjY5MS0yLjA2OC00LjY1OCwxLjMwMi01LjA1LDQuMDUzLS4zLDIuMTA1LDIuMzEyLDEuNjEsMy42OTIuODk3LDEuMjQ1LS42NDQsMy4xODEtMi43MiwxLjM1OC00Ljk0OVpNMTUxLjA2NiwyMjYuNjU5YzAtLjYxNS0uNDk5LTEuMTEzLTEuMTEzLTEuMTEzcy0xLjExMy40OTktMS4xMTMsMS4xMTMuNDk5LDEuMTEzLDEuMTEzLDEuMTEzLDEuMTEzLS40OTksMS4xMTMtMS4xMTNaIiBmaWxsPSIjMmQ4NmQxIi8+CiAgPHBhdGggZD0iTTQ3Ny4xMTEsNTk0LjY1OGwtMjEuMzM5LDIxLjgxMy0yLjcsMy4zMDMtMTIuMjc2LDEyLjcxN2MtMi41NzMsMi42NjYtNS4zMDMsNS4wMTktOC42MjksNi42MzJsLTEyLjc5Ny0xMy4wMjItMTYuMzY4LTE2LjM3My03LjA0Ni03LjIyMy00Mi44NjEtNDIuODQ5LTYuMTU5LTYuMDQ5LTI1LjQ2MS0yNS4zNzljLTMuNjQ2LTMuNjM0LTYuODU3LTcuMDYtMTAuNTE2LTEwLjYwM2wtMjEuMzIzLTIwLjY0NC0xMS4xNDItMTEuODQtMTcuNzAyLTE3LjI0My0zMS41NTMtMzEuNjY2LTE2LjQ5OS0xNi40MTYtNzYuODgxLTc2LjkyMS02LjA2NC02LjEzMi00MS45ODQtNDEuODgxLTE0LjEyMy0xNC45NDljLTkuMzg1LTkuOTM0LTE3Ljg3LTE5Ljg5LTIzLjY4OS0zMi4yOTQtMTIuNzA4LTI3LjA4OC0xNS4xOTUtNTcuMTk0LTUuNDI4LTg1LjA2N2wxNC44OTYsMTMuNDdjMy4xMzUsMi45NDEsNS41NzQsNS41NDIsOC42MTUsOC41NzRsNDguOTgxLDQ4LjgyMyw0Ljc0LDQuNjg4LDM1MS43ODksMzUxLjU1YzEuOTA0LDEuOTAzLDIuOTE0LDIuOTkzLDMuNTE4LDQuOTgyWiIgZmlsbD0iIzIwNzZjNSIvPgogIDxwYXRoIGQ9Ik02NDUuODM4LDQzMy4zMjhsMTEuMzgyLDExLjgwNS0zLjU1NSw0LjMxM2MtLjc1Ni45MTctMi4wMTIsMi4xMTUtMi45NjgsMi45MjVsLTQuODk4LDQuMTVjLTEuODUsMS41NjctMy40MjYsMy4wODQtMi43OTMsNS40OTQtMS44MjUtLjUzNC0yLjY5Ny0uMDYtNC4zNDMsMS41OTFsLTE2MC45MzIsMTYxLjQ2NiwxMTUuMTIyLDExNC40NTIsMTIuNDQ1LDEyLjM0My0xOC42NzEsMTguNjUzLTcuMTM2LTYuODg4Yy01LjA4Ny0xLjI3Mi00LjU4NC00LjQxMy03LjQyNC03LjI1N2wtMTA4LjczOS0xMDguODcxYy0xLjQ4NC0xLjQ4Ni0yLjE4NS0yLjQ2LTIuNzk3LTQuMTc0bDEwLjQ4NC0xMS41MDktMTUuMjQ1LTE1LjM1MSwyMS4zMzktMjEuODEzLDE1MS4xNjUtMTUxLjQyMSwxNC43MTUtMTQuNzQ5Yy0uNjA5Ljg5NC0uNjA1LDIuMTg3LjQwOCwyLjk2NmwyLjQzOSwxLjg3NVoiIGZpbGw9IiM3Yjg0ODYiLz4KICA8cGF0aCBkPSJNMjUuMDUzLDE0OC41MTNjLS4wNSwyLjM4MS0xLjk2OCwzLjc1Mi0yLjg2NSw1LjM3My0uMjgxLTEuMjA0LS4zMzYtMi4yNTMtLjE0Mi0zLjYxNy4yMTgtMS41MzcsMS40MTgtMS42NTEsMy4wMDctMS43NTZaIiBmaWxsPSIjZjJmM2YzIi8+CiAgPHBhdGggZD0iTTExMy44MTksNzguMTQzYy44NTktMi4yNzQsMi4zNDYtMy44MzEsNC4zNDUtNC40OTMtMS42MDEsMS42MzUtLjYxLDQuNDMyLTQuMzQ1LDQuNDkzWiIgZmlsbD0iIzJlODRjZCIvPgogIDxwYXRoIGQ9Ik0yOS44MjIsMTQyLjQzNGMtLjE4NiwxLjEyNy0uOTE5LDEuOTMtMS45MTcsMi40MDRsLjMwMi0xLjQ5NmMuMTE3LS41OC45OTUtLjkzOSwxLjYxNS0uOTA4WiIgZmlsbD0iI2YyZjNmMyIvPgogIDxwYXRoIGQ9Ik0xNi45NywyNTMuNzQ3Yy0uOTM4LS4yNzUtMS4wOTgtMS40NjUtLjc2My0yLjM1Ni4yODQuNzQ2Ljc0MiwxLjQ0NS43NjMsMi4zNTZaIiBmaWxsPSIjYmVjNmM4Ii8+CiAgPHBhdGggZD0iTTM4Mi40NDMsMTQxLjk5OWwtMi45MzktMi43NjdjLjUxMS0xLjM1Ni0uMTMxLTIuOTgzLTEuMDQtMy45MjYtMS45MzgtMi4wMTEsMS4xMzQtMy44MiwxLjE1OS00Ljk3NmwuNzM2LTMzLjU1M2MuMDg3LTMuOTg5LS4yNC04LjQwNywzLjA4NS0xMS44NDdsLjUxOCw1Mi43NjZjLjAxOSwxLjg5Ny0uMTc2LDMuMzE3LTEuNTE4LDQuMzAzWiIgZmlsbD0iI2NmZDVkNiIvPgogIDxwYXRoIGQ9Ik02NDMuMDA3LDQ2Mi4wMTZsNC40MDQsNC4yN2MxLjY3OCwxLjY2NSw0LjU3My40Myw2LjQ1Ni41ODZsNS4wMTcuNDE3LjIxMyw5Ljk2MiwxOS41NDYsMTkuNjUyLDM0LjcxMiwzNC41NzYsMjkuMzY5LDI5LjM5MSwyNi43NTMsMjYuNzI1LTE0Ljg0LDE0LjgzMy0xNDkuMzM3LDE0OS40NDEtMTIuNDQ1LTEyLjM0My0xMTUuMTIyLTExNC40NTIsMTYwLjkzMi0xNjEuNDY2YzEuNjQ1LTEuNjUxLDIuNTE4LTIuMTI1LDQuMzQzLTEuNTkxWk02NDkuMjUyLDU0My45MDhsLTMxLjEzLDMxLjYxMWMxLjk0OSwzLjI2NCw2LjEzMSw3LjkxLDguOTc4LDguMTA5bDE3LjA0OCwxNi42MjVjLS4xNTUuNzY2LS4wMzksMS43ODUuNDYzLDIuMjYzLjY4LjY1LDEuNzcuODg5LDIuNzE3LjkybDEuODE3LDEuOTEzYy0uMTQ5LjUwMS0uMjAzLDEuMTM0LS4wNjIsMS43MDQuMTMxLjUzLjc5Mi44NzUsMS4zNjkuNjA2bC42ODUtLjVjLS4wNTEtLjE0Ni0uMDQ1LS4zMDUsMC0uNDQ4bDMwLjU2Ni0yOS4zODZjMS42NjEuMzg4LDIuOTQsMS4xMzksNC4xNDcsMi41bDM5LjE2NywzOS4zMDQsMjQuNzg1LTI1LjE0Ny0xMTcuNjQxLTExNy44MjMtMjUuMDU0LDI0Ljg2Niw0Mi4xNDcsNDIuODgzWk01NDYuNTU1LDY0Ny4yMzdjLjEyLjQxMi0uNjcyLjc4OC0uNTE5Ljk4Ni40NDUuNTc3LDEuNzcyLjYxOSwyLjEyNS4yN2wzMC4wMSwyOS44NjNjLS4zMi42MDctLjMxLDEuMzc3LS4xOTQsMS43ODkuMTUyLjUzOS45ODIuODU4LDEuNDcxLjUxNi42NDItLjQ1LjcxMS0xLjMzNi40NTMtMi4xNzNsMTEuODgtMTEuOTI2LDEuMTA5LTEuMDJjMi4wMDYtMS44NDQsMy42MjktNC4zODcsNS45OC01LjkzMS4zODYtLjI5OC43OTMtLjY5OS45MDUtMS4yNjNsMjMuODIyLTIzLjg3OS0zMi40MS0zMi40ODYtNDQuNjMxLDQ1LjI1NlpNNjUxLjUyMiw2MDcuNTgzbC0uMjQ3Ljg0MmMtLjIyOS0uMDc3LDEuMDUxLS4wMDUuMjQ3LS44NDJaIiBmaWxsPSIjOWFhNGE1Ii8+CiAgPHBvbHlnb24gcG9pbnRzPSI4NjQuMDg3IDc2OC4xMTQgNjYwLjc2NSA3NjguMjMzIDY2MC45NDMgNzM4Ljg5MiA4NjMuOTc2IDczOC44MjggODY0LjA4NyA3NjguMTE0IiBmaWxsPSIjYjJiYWJjIi8+CiAgPHBhdGggZD0iTTkyMS4wNjIsODI5LjA3NGMtMi42NDUsMTIuOTgzLTEzLjg3Niw0LjkyLTIyLjIxMiw5LjQ4OC0xLjk5OS0uODE3LTQuODM1LS4wMDQtNi45NTctLjAxbC0zMy44NjQtLjA5NC03LjIwMS4wMDMtMjkuNDgyLS4xNzdjLTguODAyLTEuMjIzLTE2LjYzOC40MjItMjUuNDgyLjIyM2wtNy45ODktLjE3OS0yMC43MDEtMS4wMDNjLTUuMjE2LS4yNTMtOC41NTktMS4wMTctMTMuNTgzLjg5Mi00Ljc1MywxLjgwNi0xMS4yMS4wNTQtMTYuMjkyLjE5OWwtMTguMzI1LjUyMS0xNy4xNzctMS44MTItMTMuNjE5Ljk2OWMtMTAuNDM4Ljc0My0xOC43NDEtMS40MjQtMjcuODUzLjAzLTMuMTA5LjQ5Ni00Ljc0OS4wMjYtNy42ODUtLjAyOWwtNDMuMzY3LS44MTZjLTMuMzAzLS4wNjItNS4zMDItLjI0OS04LjY5Ny0uMDg2bC0yNS41OTgsMS4yMjZjLTQuNjE1LjIyMS04LjQ3NC4wMjQtMTMuMTE4LS4yNDUtNC4yMjktLjI0NS05LjAzMiwxLjgyOS0xMy40ODguMTU2LTQuODc3LTEuODMxLTkuNjQ4LjExNy0xNC41NDcuMTVsLTYxLjgzMS40MTktOS4xMzYtMS4wMDYtMzYuNjE2LS4wMDQtMTEuMTI1LjI0LTExLjE3My0uNDQ4Yy03LjA4MiwxLjAxMy0xMy4zNzQtMi42MjEtMTYuMTA2LTguNjEzbDUzMy4yMi4wMDdaIiBmaWxsPSIjYmVjNmM4Ii8+CiAgPHBvbHlnb24gcG9pbnRzPSI1NzMuMzU1IDI1NC41NzIgNjE5LjQxNCAzMDEuMjIzIDU0Mi4yNzkgMzAyLjA4OSA0OTYuMDk2IDI1NS4wOSA1NzMuMzU1IDI1NC41NzIiIGZpbGw9IiM2MWM2ZjYiLz4KICA8cGF0aCBkPSJNNTk2Ljk0MSwzNTcuNjUxYy0uODExLjQ4LTIuNDI4LDEuMjM1LTMuMzI1LjgyNC0uMjA2LS4wOTQtMy45NzYtNS4xMTgtMi45NDUtNi43NDIsMi42MjUsMS4yMTEsNC43LDMuNTQyLDYuMjcsNS45MThaIiBmaWxsPSIjMmQ4NmQxIi8+CiAgPHBhdGggZD0iTTY2Mi44NzEsNDY2Ljg2NGwtMy45ODcuNDI1LTUuMDE3LS40MTdjLjIyNi02LjE1NS0xLjAyNC0xNC43MjktLjQxMy0xNC4zNDQtLjQ5My0uMzExLTIuMjM3LjE1OS0yLjc1Ni0uMTU2Ljk1Ni0uODEsMi4yMTEtMi4wMDgsMi45NjgtMi45MjUsMS45Ny0uNTQyLDQuMzI3LTEuMjA1LDYuMDIyLS4wOTgsMS4yNDcuODE1LDMuNzE0LDIuOTEzLDMuNjQyLDUuMTA3bC0uNDU5LDEyLjQwN1oiIGZpbGw9IiNjZmQ1ZDYiLz4KICA8cGF0aCBkPSJNMzAwLjM5MiwzMDUuMDAyYzEuODE5LS4wMDYsMS43NjQtMi43NTksMi45MDMtMy44NzlsMjAuMjI3LTE5Ljg4NmMzLjgyOC0zLjc2Myw3Ljk5NS02Ljc3MSwxMC42MDQtMTEuNzg0bC0zNS41ODMsMjEuMzM5LTcwLjY1MSw0MC41NjgtMjIuMjktMjIuMTgzYzQuMTMyLTYuMTQ1LDcuMDgyLTExLjQ3OCwxMC41MzktMTcuNDc4bDUyLjgxNy05Mi4yMzEtMTUuNjAyLDE1LjcyMi03MC45MTIsNzEuMTg1LTE2LjQyNi0xNi4wNjctNS4zMTgtNS41ODcsNi40MzYtNy4yNDhjMi4xNy0yLjQ0Myw0Ljg1Mi00LjY3Niw3LjE1Mi02Ljk3NGw3Ljk0Mi03LjkzNWM1LjEwMi0yLjk5NCw3LjI0NS04LjI3NiwxMS4zODctMTIuMjg2LDQuNjA3LTQuNDYyLDExLjE2Ni03LjczNiwxNC4wOTMtMTMuNjg0LDEuNjMyLTMuMzE1LDQuNjI4LTMuODg2LDYuOTk3LTYuMjgybDMxLjE5OS0zMS41NWMzLjk4OS00LjAzNCw4LjAyNS03LjY4NiwxMi4yMjgtMTIuMDc5bDUuMDMtNS4yNTcsMjAuNTI0LTE5LjQzOSwzMi43NywzMi43OTEtMTEuODg4LDIwLjcwNi00OC42ODEsODYuMzI1LDI4LjY1Ni0xNi42NzYsNTcuMDQtMzMuODAzLDE5LjMyNi0xMi4yODQsMzQuMDk5LDM0LjI1LTEyMi45MjksMTIzLjA4NWMtNi4xMjktOC40NzYtMTkuODk3LTE3Ljk5My0yMC4xNTUtMjEuMjA3LS4xNS0xLjg2OCwxLjUwNS0yLjU0LDIuNzkxLTMuODQ1bDQ1LjY3My00Ni4zMjlaIiBmaWxsPSIjZjFmNWY1Ii8+CiAgPHBhdGggZD0iTTIzMy44OTIsNTcuOTVjMS4yMzEuMDI4LDIuNjU2Ljk4Niw0LjA1My45MiwyLjM1OS0uMTExLDQuNjU5LjY0NSw2Ljg5NywxLjI4bDIuMjI2LjM2OSwxOC40NTgsOC42NDZjMi4zMDksMS4wODIsNC4zODYsMy45NjIsNi43OTIsMy42NzUuNzY0LDIuNDgzLDMuMDc5LDIuNzM5LDUuMDY1LDQuNzI1bDMzNi4yNSwzMzYuMTM5YzUuNDg3LDQuOTA2LDEwLjQsOS4wMDQsMTQuNzg1LDE0Ljk5NWwtMjEuODkxLDIyLjE0LTE1NC4yMjUtMTU0LjIzOGMtMi4yNzYtMi4yNzYtNC4wNC0yLjkxMy01Ljk1NS01LjU3OC0yLjIwNy0zLjA3Mi01LjY5OC02LjUwNC04Ljc2Ny04LjgyOS0zLjkwMi0yLjk1Ny02LjI4NC02LjI0Ni05LjY0OS05LjYxMmwtMjQuNC0yNC40MDMtNi41MTktNi44MzVMMjIxLjMwOCw2NS41NjFsLTguMzI5LTYuNzY5Yy4xNi0uNzE5LjY5MS0xLjMwMiwxLjkwNi0xLjI3NWwxOS4wMDYuNDMyWiIgZmlsbD0iIzRmOWFkNCIvPgogIDxwYXRoIGQ9Ik00MDkuMjc4LDQ2OC43NDVsOC4wOTcsOC44NzktOC4zNSw4LjA3Ni0xMy42MDQsMTMuOTgxLTMwLjc3OC0zMC44MzYtMjIuOTg2LTIyLjY2Ni0xNS4wMDktMTUuMTI0LTguMjUzLTguNTMyLTIzLjM3LTIzLjg2NS0xMC41MzMtMTAuNTU4LDIxLjkzOC0yMS42OTgsMTYuMzk3LDE2LjI1MSwxMTguMzg5LTY1LjUzOSwxMS40ODgtNi41MzYsMjAuOTMsMjEuNDc5YzEuODIyLDEuODctMS4wNjYsNC4wMDctMS45MjUsNS41MzRsLTYzLjIyMywxMTIuNDA3LTYuNjIyLDExLjYxOSw3LjQxNiw3LjEyNlpNMzUyLjI2NCw0MDAuMzE2Yy0yLjYyNiwxLjQ1NS00LjU4NywzLjI0Mi03LjM1MSwzLjcxNGw0LjYzNSw0Ljc1NiwzMC4wNjEsMzAuMjkyLDM4LjQzLTY5LjM2NGMxLjE1NC0yLjA4MywyLjQzOS0zLjUzNCwxLjY1MS02LjQ4Ni0yLjMyNCwyLjYzLTUuNjUyLDIuODcxLTguNzAxLDQuNTZsLTU4LjcyNiwzMi41MjhaIiBmaWxsPSIjZjFmNWY1Ii8+CiAgPHBhdGggZD0iTTE3MS4xNTIsMjM5LjkxYy0yLjE0LDEuMTk5LS4zMjMsNS41NjMtMS45NzksOC40ODktLjM4OS42ODctMi44NTksMS4yNDItMi45NDYtLjAyNWwtLjU4MS04LjQ4M2M0LjkyLTMuNTgzLDUuNzk3LTcuODQsOS41NDUtNy4wNDEsMS4xMTIuMjM3LDMuMzQ5LDIuMzE4LDIuNTUxLDMuMzY5bC02LjU5LDMuNjkxWiIgZmlsbD0iIzJkODZkMSIvPgogIDxwYXRoIGQ9Ik0zMDAuMzkyLDMwNS4wMDJjLS4yMDMtMS43NjQuODUyLTMuMDA5LDEuODU2LTQuMDRsMTcuODc4LTE4LjM1NmMuNzA5LS45MTQtLjk5LTIuOTE4LTIuMjc1LTIuMTA3bC0xMS4xNzMsNy4wNTZjLTIuNjU0LDEuNjc2LTUuNzMxLDEuODU3LTguMTMzLDMuMjM3bDM1LjU4My0yMS4zMzljLTIuNjA5LDUuMDEyLTYuNzc2LDguMDItMTAuNjA0LDExLjc4NGwtMjAuMjI3LDE5Ljg4NmMtMS4xNCwxLjEyLTEuMDg0LDMuODc0LTIuOTAzLDMuODc5WiIgZmlsbD0iIzFhNjA5ZiIvPgogIDxwYXRoIGQ9Ik0yODMuODYyLDE0MS40MDdjLTIuODMxLTMuOTM0LTYuNTkzLTcuNDM0LTcuOTgxLTExLjQ4NiwxLjQ0LTMuNDQ5LDEwLjM5NiwzLjI3OSwxMC43MDEsNC43NTIuNDYyLDIuMjMzLDEuMzQ3LDQuNzU1LTIuNzIsNi43MzRaIiBmaWxsPSIjMmQ4NmQxIi8+CiAgPHBhdGggZD0iTTMwMy40NzgsMTU4LjYwMWMtMS4wMy0uNDc2LTIuMTM2LTEuMTI2LTMuMDUxLTEuOTQ2LS43NTgtLjY3OS41MzctMi4yMDUsMS43OTEtMy4yNTctMi45NjMtLjYzOC00LjUwOC0uNzctNi40NDItMi4xMzQtMS41NDUtMS4wOS0yLjk2Ni01LjAwOS0uNDY5LTYuMTg0LDIuMjc5LTEuMDcxLDQuMDU0LDMuNjAyLDUuMzk3LDQuNjk0bDMuOTU4LDMuMjJjLS4zOTIsMS43NDUtLjU3MywzLjQyMi4wNzIsNC43NzQuMDQyLjA4OC4wNDkuMTg4LjAzNS4yODIuMzI0LjA4NCwxLjQ1My43NzYsMS40NiwxLjE4Ni4wMS41OTctLjczOS44MTktMS4wNjUsMS4wNS0uNjY1LjQ3MS0xLjkxLjE2NC0xLjM3LTEuMDc2bC0uMzE2LS42MDlaIiBmaWxsPSIjMmQ4NmQxIi8+CiAgPHBhdGggZD0iTTI1My45NjcsMTU0LjcyOWMtLjQwOCw0Ljc2Ny02LjIyMywxMS4wNDgtOC42MTIsOC4wMy0yLjQ5Mi0zLjE0OSw0LjU5OC0zLjQ4Nyw1LjY5MS04LjkwNS40MTctMS4wMTUsMy4wNTUtLjY4OSwyLjkyMS44NzZaIiBmaWxsPSIjMmQ4NmQxIi8+CiAgPHBhdGggZD0iTTQwOS4yNzgsNDY4Ljc0NWMxLjU2Ny0uMDIyLDIuNDA1Ljc5OCwzLjYyNCwyLjAzbDUuMjg2LDUuMzRjMS41MDYsMy4xMDItMS43ODUsNC4wNDItMy4yNjQsNS41MDlsLTYuMDc3LDYuMDI3Yy0xLjA5NiwxLjA4Ny0xLjgyNiwzLjgxNC0zLjI5NSw0LjQyLTQuMTcxLDEuNzIxLTYuMzY2LDQuMzQ2LTguMjM4LDguMjc4LS42MzUsMS4zMzMtMy43MjMtLjIzNi00LjQ0OS0xLjQ4Ny0xLjg3Ny0zLjIzNi01LjQ4OC00LjEzNS03LjU2NC02LjcxN2wtNC44MzMtNi4wMTEtOC43NTUtOC4wODRjLTEuOTU0LTEuODA0LTIuODctMi44OTctNC42MjctNC42NThsLTExLjg4Mi0xMS45MDhjLTEuNjQtMS42NDQtMi40NjEtMi4zNTktNC4xNTItNC4wNjZsLTExLjQ1LTExLjU1N2MtMS45MjQtMS45NDItMy41MjgtMy4zMTUtNS41NzktNS40MjlsLTEwLjI2My0xMC41NzVjLTIuMjctMi4zMzktNS42MTYtMy44NzItNS4zNjYtNy4zMzdsOC4yNTMsOC41MzIsMTUuMDA5LDE1LjEyNCwyMi45ODYsMjIuNjY2LDMwLjc3OCwzMC44MzYsMTMuNjA0LTEzLjk4MSw4LjM1LTguMDc2LTguMDk3LTguODc5WiIgZmlsbD0iIzIwNzZjNSIvPgogIDxwYXRoIGQ9Ik0yODAuMDA5LDE0MS40MThjLS43NzksMS43MjItMS44ODQsMi4yOTktMi45MywzLjMzMS0yLjUwOC0xLjUzOC00LjA1OS0zLjkxOC0yLjM5NC02LjMzNSwyLjI3Ni42MzIsMy4zMzQsMS40NDgsNS4zMjQsMy4wMDRaIiBmaWxsPSIjMmQ4NmQxIi8+CiAgPHBhdGggZD0iTTE2Ni4wMTgsMjcwLjMwOGMtMS43MzctLjE1LTUuOTcyLTMuMTA4LTUuOTE2LTUuNTI5LjM2MS0zLjQ5NCw0LjM5Ni02LjA0Myw3LjAzNC03LjMwNmwtNi40MzYsNy4yNDgsNS4zMTgsNS41ODdaIiBmaWxsPSIjMjA3NmM1Ii8+CiAgPHBhdGggZD0iTTE4Mi4yMywyNDIuNTY1bC03Ljk0Miw3LjkzNWMtLjM1OC0xLjg3MywxLjkwNS0yLjc3NSwzLjA4NS00LjMwNiwxLjQ5My0xLjkzOCwyLjQ0Mi0zLjY0Miw0Ljg1Ny0zLjYyOVoiIGZpbGw9IiMxYTYwOWYiLz4KICA8cGF0aCBkPSJNMjYzLjE2NSwxNjEuNDI3bC01LjAzLDUuMjU3Yy00LjIwNCw0LjM5My04LjIzOSw4LjA0NS0xMi4yMjgsMTIuMDc5LjA2My0xLjQxOSwxLjA1My0yLjUyMSwyLjMwNS0zLjg3NmwzLjY5OS00LjAwM2MxLjY1OS0xLjc5NiwyLjg3Ni0zLjQ4NCw0Ljk1OC01LjM0NmwzLjE5OC0yLjg2MSwxLjgzLTEuNTA1Yy41NjUtLjQ2NSwxLjI5Ni0uNDQ2LDEuMjY4LjI1NloiIGZpbGw9IiMyMDc2YzUiLz4KICA8cGF0aCBkPSJNMjY1LjYzNywxMzcuNjA3YzEuNzI3LDMuNTQ2LTMuMzI5LDcuNTc2LTUuOTA4LDcuMDQ4LTEuMzMtMi45NzEuMjQyLTMuOTkxLDEuMDM3LTUuNzU2LjY3LTEuNDg4LDMuNjQ0LTMuODEsNC44Ny0xLjI5MloiIGZpbGw9IiMyZTg0Y2QiLz4KICA8cGF0aCBkPSJNMjMzLjEwNCwxNjguMjI3YzEuODM0LDEuMTk2LDEuMDY4LDQuMjMtMS4yMjIsNi45MzctLjg4NSwxLjA0Ni0zLjg3OC43MjItMy44MTUtLjI2Ny4xNzktMi44MjcsMi45OTgtOC4wMDEsNS4wMzgtNi42N1oiIGZpbGw9IiMyZTg0Y2QiLz4KICA8cGF0aCBkPSJNMjE3LjM3MywxODUuMjczYzEuODIzLDIuMjI5LS4xMTMsNC4zMDYtMS4zNTgsNC45NDktMS4zOC43MTMtMy45OTIsMS4yMDktMy42OTItLjg5Ny4zOTItMi43NTEsMy4zNTktNi4xMjEsNS4wNS00LjA1M1oiIGZpbGw9IiMyZTg0Y2QiLz4KICA8cGF0aCBkPSJNMjQxLjY4OCwxNjguMzMyYy44MjcuMzUyLjEzMSwyLjU0NS0xLjI3MywyLjQ3Ni0xLjI5LS4wNjQtMi44NTQuMDc1LTIuODg2LTIuNTY3bDQuMTU5LjA5MloiIGZpbGw9IiMyZTg0Y2QiLz4KICA8cGF0aCBkPSJNMTA2LjQ4OCwxMDUuMjIyYy0uODA1LjUzOS0xLjY1MS40Ny0yLjA2NC0uMjk5LS40MDUtLjc1Ni0uMzczLTEuMTkuNjczLTIuMTgyLjg0My0uNzk5LDEuNzMxLS42LDIuMjY1LS4yNjcuMzk3LjI0Ny44OS45MzMuODA0LDEuNjItLjA1OS40NjgtMS4yNi44NDgtMS42NzksMS4xMjhaIiBmaWxsPSIjMmU4NGNkIi8+CiAgPHBhdGggZD0iTTIzNy45NDQsNTguODdjLTEuMzk3LjA2Ni0yLjgyMi0uODkyLTQuMDUzLS45Mi4yNi0xLjUxOCwxLjQxOC0xLjQ1LDIuNTUzLTEuMzk4LDEuMzg1LjA2MiwxLjkwMi44NjksMS40OTksMi4zMTlaIiBmaWxsPSIjMmU4NGNkIi8+CiAgPGNpcmNsZSBjeD0iMTQ5Ljk1MyIgY3k9IjIyNi42NTkiIHI9IjEuMTEzIiBmaWxsPSIjMmU4NGNkIi8+CiAgPGNpcmNsZSBjeD0iMjIxLjk1MyIgY3k9IjE3Mi42NTkiIHI9IjEuMTEzIiBmaWxsPSIjMmU4NGNkIi8+CiAgPHBhdGggZD0iTTI0Ny4wNjgsNjAuNTE5bC0yLjIyNi0uMzY5Yy4xNTctLjM1OS4zODItLjguOTAyLTEuMjc5LjI3OS0uMjU3Ljc5LS4xMzYuOTM0LjM0NWwuMzksMS4zMDJaIiBmaWxsPSIjMmU4NGNkIi8+CiAgPHBhdGggZD0iTTY1My44NjYsNDY2Ljg3MmMtMS44ODMtLjE1Ni00Ljc3NywxLjA3OS02LjQ1Ni0uNTg2bC00LjQwNC00LjI3Yy0uNjMyLTIuNDA5Ljk0NC0zLjkyNiwyLjc5My01LjQ5NGw0Ljg5OC00LjE1Yy41MTkuMzE1LDIuMjYzLS4xNTQsMi43NTYuMTU2LS42MTItLjM4NS42MzksOC4xODkuNDEzLDE0LjM0NFoiIGZpbGw9IiNiZWM2YzgiLz4KICA8cGF0aCBkPSJNNjgxLjcwMiw1NzcuMzI1bDE1LjExMy0xNC45ODYtMzIuOTExLTMzLjE5Ni0xNC42NTIsMTQuNzY1LTQyLjE0Ny00Mi44ODMsMjUuMDU0LTI0Ljg2NiwxMTcuNjQxLDExNy44MjMtMjQuNzg1LDI1LjE0Ny0zOS4xNjctMzkuMzA0Yy0xLjIwNy0xLjM2MS0yLjQ4Ni0yLjExMy00LjE0Ny0yLjVaIiBmaWxsPSIjYmVjNmM4Ii8+CiAgPHBhdGggZD0iTTY4MS43MDIsNTc3LjMyNWwtMzAuNTY2LDI5LjM4NmMtLjY0OS0uMzUzLTEuNDgyLS44MjYtMS45OTEtMS4zNjJsLTEuODE3LTEuOTEzLTMuMTc5LTMuMTgzLTE3LjA0OC0xNi42MjVjLTIuNzU0LTIuNjg2LTYuMDYxLTQuNzM4LTguOTc4LTguMTA5bDMxLjEzLTMxLjYxMSwxNC42NTItMTQuNzY1LDMyLjkxMSwzMy4xOTYtMTUuMTEzLDE0Ljk4NloiIGZpbGw9IiM3Yjg0ODYiLz4KICA8cGF0aCBkPSJNNTk5Ljc3NCw2NTguMzQ2bC0uOTA1LDEuMjYzYy0yLjM1MiwxLjU0NS0zLjk3NCw0LjA4Ny01Ljk4LDUuOTMxbC0xLjEwOSwxLjAyLTExLjg4LDExLjkyNi0xLjcyOS0uMTMxLTMwLjAxLTI5Ljg2My0xLjYwNS0xLjI1Niw0NC42MzEtNDUuMjU2LDMyLjQxLDMyLjQ4Ni0yMy44MjIsMjMuODc5WiIgZmlsbD0iIzdiODQ4NiIvPgogIDxwYXRoIGQ9Ik01NzkuODk5LDY3OC40ODZjLjI1OS44MzguMTg5LDEuNzI0LS40NTMsMi4xNzMtLjQ4OC4zNDItMS4zMTkuMDIzLTEuNDcxLS41MTYtLjExNi0uNDEyLS4xMjYtMS4xODIuMTk0LTEuNzg5bDEuNzI5LjEzMVoiIGZpbGw9IiNiMmJhYmMiLz4KICA8cGF0aCBkPSJNNjUxLjEzNSw2MDYuNzFjLS4wNDUuMTQzLS4wNS4zMDIsMCwuNDQ4LjA2Ny4xOTIuMjIyLjM1My4zODYuNDI1LjgwNC44MzgtLjQ3Ny43NjUtLjI0Ny44NDJsLS44MjQtLjc2N2MtLjU3Ny4yNy0xLjIzOC0uMDc2LTEuMzY5LS42MDYtLjE0MS0uNTctLjA4Ni0xLjIwNC4wNjItMS43MDQuNTA5LjUzNiwxLjM0MywxLjAwOSwxLjk5MSwxLjM2MloiIGZpbGw9IiNiMmJhYmMiLz4KICA8cGF0aCBkPSJNNjQ3LjMyNyw2MDMuNDM1Yy0uOTQ3LS4wMzEtMi4wMzYtLjI3LTIuNzE3LS45Mi0uNTAxLS40NzktLjYxNy0xLjQ5OC0uNDYzLTIuMjYzbDMuMTc5LDMuMTgzWiIgZmlsbD0iI2IyYmFiYyIvPgogIDxwYXRoIGQ9Ik02MjcuMSw1ODMuNjI3Yy0yLjg0Ni0uMTk5LTcuMDI4LTQuODQ1LTguOTc4LTguMTA5LDIuOTE3LDMuMzcxLDYuMjIzLDUuNDIzLDguOTc4LDguMTA5WiIgZmlsbD0iI2IyYmFiYyIvPgogIDxwYXRoIGQ9Ik01NDguMTYsNjQ4LjQ5M2MtLjM1My4zNDktMS42OC4zMDgtMi4xMjUtLjI3LS4xNTMtLjE5OC42NC0uNTc0LjUxOS0uOTg2bDEuNjA1LDEuMjU2WiIgZmlsbD0iI2IyYmFiYyIvPgogIDxwYXRoIGQ9Ik01OTguODY5LDY1OS42MDlsLjkwNS0xLjI2M2MtLjExMi41NjQtLjUxOS45NjUtLjkwNSwxLjI2M1oiIGZpbGw9IiNiMmJhYmMiLz4KICA8cGF0aCBkPSJNNTkxLjc3OSw2NjYuNTZsMS4xMDktMS4wMi0xLjEwOSwxLjAyWiIgZmlsbD0iI2IyYmFiYyIvPgogIDxwYXRoIGQ9Ik0zNDkuNTQ5LDQwOC43ODZjLS4yMDEtMS42Mi0xLjczLTIuNjQzLTEuNjk3LTUuMTI2LDItLjQzOSwzLjk5MS0xLjI2OCw0LjQxMi0zLjM0NGw1OC43MjYtMzIuNTI4YzMuMDQ5LTEuNjg5LDYuMzc2LTEuOTMsOC43MDEtNC41Ni43ODgsMi45NTItLjQ5OCw0LjQwMy0xLjY1MSw2LjQ4NmwtMzguNDMsNjkuMzY0LTMwLjA2MS0zMC4yOTJaIiBmaWxsPSIjMmU4NGNkIi8+CiAgPHBhdGggZD0iTTM0OS41NDksNDA4Ljc4NmwtNC42MzUtNC43NTZjMi43NjMtLjQ3Miw0LjcyNC0yLjI1OSw3LjM1MS0zLjcxNC0uNDIyLDIuMDc2LTIuNDEyLDIuOTA1LTQuNDEyLDMuMzQ0LS4wMzMsMi40ODMsMS40OTYsMy41MDYsMS42OTcsNS4xMjZaIiBmaWxsPSIjMWE2MDlmIi8+Cjwvc3ZnPg=="

let pluginIcon: NSImage? = {
    if let d = Data(base64Encoded: pluginIconB64), let img = NSImage(data: d), img.isValid {
        return img
    }
    return nil
}()

// MARK: - Интерфейс (системный стиль)

struct BridgeView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            header
            if model.oldPlugin { oldPluginCard }

            GroupBox {
                VStack(spacing: 0) {
                    statusRow(title: "Расширение Safari",
                              ok: model.extEnabled,
                              okText: "Включено", badText: "Выключено")
                    Divider().padding(.vertical, 8)
                    statusRow(title: "Служба подписи",
                              ok: model.pluginOk,
                              okText: "Запущена",
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
                HStack(alignment: .center, spacing: 13) {
                    if let icon = pluginIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 44, height: 44)
                            .accessibilityLabel("Иконка службы подписи")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Toggle("Запускать службу подписи в фоне", isOn: Binding(
                                get: { model.service == "on" },
                                set: { model.setBackgroundMode($0) }))
                            .toggleStyle(.switch)
                            .disabled(model.busy || model.service == "noplugin")
                            if model.busy {
                                ProgressView().controlSize(.small).padding(.leading, 4)
                            }
                        }
                        Text(model.service == "noplugin"
                             ? "Сначала установите КриптоПро CSP — тот же, что используется в Chrome."
                             : "Встроенная служба подписи работает в фоне без окна: запустится сама при входе в систему, отдельный плагин «Моё Дело» не нужен; при сбое macOS перезапустит её.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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

            Text("Неофициальное приложение, не связано с сервисами ЭДО.\nНужен КриптоПро — тот же, что для Chrome.")
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
    private var oldPluginCard: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Найден старый плагин «Моё Дело»")
                        .font(.headline)
                    Text("У вас установлен прежний плагин подписи для процессоров Intel — он работает через Rosetta и в новых версиях macOS перестанет запускаться. Встроенная служба «ЭДО Мост» его полностью заменяет.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        model.removeOldPlugin()
                    } label: {
                        Label("Удалить старый плагин и перейти на новый", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .disabled(model.busy)
                }
            }
            .padding(6)
        }
    }

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
                    "Смотрю состояние расширения и службы подписи.")
        }
        if model.allGood {
            return ("checkmark.seal.fill", .green, "Можно подписывать",
                    "Откройте «Моё Дело» в Safari и нажмите «Подписать» — при первом разе подтвердите доступ.")
        }
        if !model.extEnabled {
            return ("puzzlepiece.extension", .orange, "Включите расширение",
                    "Подпись в Safari заработает после включения расширения в настройках.")
        }
        return ("exclamationmark.triangle.fill", .orange, "Служба подписи не запущена",
                model.service == "noplugin"
                ? "Установите КриптоПро — без него подпись не работает."
                : "Включите фоновый режим ниже.")
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
