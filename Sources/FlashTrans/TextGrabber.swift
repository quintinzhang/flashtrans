import AppKit
import ApplicationServices

/// 取词：优先走辅助功能 API（不碰剪贴板，避免 macOS 的「允许粘贴」确认条），
/// 失败时回退到「备份剪贴板 → 模拟 ⌘C → 读取 → 还原」的经典方案（Easydict 同款）。
enum TextGrabber {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 弹出系统授权引导（辅助功能）
    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func grabSelectedText(maxLength: Int = 8000) -> String? {
        if let text = selectedTextViaAccessibility() {
            return trimmed(text, maxLength)
        }
        return copyViaPasteboard(maxLength: maxLength)
    }

    // MARK: - 方案一：辅助功能直读选中区

    private static func selectedTextViaAccessibility() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedValue = focusedRef else { return nil }
        let focused = focusedValue as! AXUIElement // success 时必为 AXUIElement
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &valueRef) == .success,
              let text = valueRef as? String, !text.isEmpty else { return nil }
        return text
    }

    // MARK: - 方案二：模拟 ⌘C 走剪贴板

    private static func copyViaPasteboard(maxLength: Int) -> String? {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(pasteboard)
        let baseline = pasteboard.changeCount
        postCommandC()

        var found: String?
        let deadline = Date().addingTimeInterval(0.45)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            if pasteboard.changeCount != baseline {
                Thread.sleep(forTimeInterval: 0.05) // 等目标 App 写完所有类型
                if let text = pasteboard.string(forType: .string) {
                    found = text
                    break
                }
            }
        }
        snapshot.restore(to: pasteboard)
        return trimmed(found ?? "", maxLength)
    }

    private static func postCommandC() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let virtualKey = CGKeyCode(8) // kVK_ANSI_C
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    // MARK: - 工具

    private static func trimmed(_ text: String, _ maxLength: Int) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.count > maxLength {
            return String(value.prefix(maxLength)) + " …（过长已截断）"
        }
        return value
    }

    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]

        static func capture(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
            var snapshot: [[NSPasteboard.PasteboardType: Data]] = []
            for item in pasteboard.pasteboardItems ?? [] {
                var entries: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) {
                        entries[type] = data
                    }
                }
                snapshot.append(entries)
            }
            return PasteboardSnapshot(items: snapshot)
        }

        func restore(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()
            let restored = items.map { entries -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in entries {
                    item.setData(data, forType: type)
                }
                return item
            }
            pasteboard.writeObjects(restored)
        }
    }
}
