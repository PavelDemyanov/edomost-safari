//
//  AppDelegate.swift
//  MoeDeloBridge
//
//  Created by redpax on 09.06.2026.
//

import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Отладочные флаги: управление фоновым режимом плагина из терминала
        // (используются для автотестов, на обычный запуск не влияют).
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--service-on") {
            do { try PluginService.enable(); print("service: on"); exit(0) }
            catch { print("service: error — \(error.localizedDescription)"); exit(1) }
        }
        if args.contains("--service-off") {
            PluginService.disable(); print("service: off"); exit(0)
        }
        if args.contains("--service-status") {
            print("service: \(PluginService.state)"); exit(0)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Автозапуск встроенной службы подписи: при первом старте (и далее, пока
        // пользователь сам её не выключил тумблером) поднимаем демон в фоне, чтобы
        // подпись работала «из коробки». enable() идемпотентен — если служба уже
        // запущена, ничего не делаем.
        DispatchQueue.global(qos: .userInitiated).async {
            let userDisabled = UserDefaults.standard.bool(forKey: "serviceUserDisabled")
            if PluginService.cspInstalled && !PluginService.enabled && !userDisabled {
                try? PluginService.enable()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

}
