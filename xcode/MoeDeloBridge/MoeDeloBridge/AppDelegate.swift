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
        // Override point for customization after application launch.
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

}
