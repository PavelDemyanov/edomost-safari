//
//  SafariWebExtensionHandler.swift
//  MoeDeloBridge Extension
//
//  Расширение НЕ использует нативные сообщения. Вся логика и единственный
//  сетевой вызов (к локальному плагину на 127.0.0.1) находятся в JavaScript —
//  см. extension/background.js. Эта нативная часть сетевых запросов НЕ делает
//  и оставлена пустой намеренно.
//

import SafariServices

class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        // Ничего не делаем: нативная часть не выполняет сетевых операций.
        context.completeRequest(returningItems: [], completionHandler: nil)
    }
}
