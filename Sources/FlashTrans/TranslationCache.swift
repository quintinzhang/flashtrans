import Foundation

/// 翻译结果本地缓存：JSON 文件持久化，按「文本+目标语言」命中，天数过期 + LRU 淘汰。
/// 命中时零网络请求、瞬时返回（elapsedMs = 0, fromCache = true）。
final class TranslationCache {
    static let shared = TranslationCache()

    private struct Entry: Codable {
        var translation: String
        var model: String
        var lastUsed: Date
    }

    private var entries: [String: Entry] = [:]
    private let lock = NSLock()
    private let fileURL: URL

    private init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FlashTrans", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("cache.json")
        if let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = stored
        }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    func lookup(_ text: String, to target: String) -> TranslationOutcome? {
        let days = AppSettings.shared.cacheDays
        guard days > 0 else { return nil }
        let key = Self.key(text, target)
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[key] else { return nil }
        guard Date().timeIntervalSince(entry.lastUsed) < Double(days) * 86400 else {
            entries.removeValue(forKey: key)
            persistLocked()
            return nil
        }
        entry.lastUsed = Date()
        entries[key] = entry
        persistLocked()
        return TranslationOutcome(translation: entry.translation, model: entry.model, elapsedMs: 0, fromCache: true)
    }

    func store(_ outcome: TranslationOutcome, text: String, to target: String) {
        guard AppSettings.shared.cacheDays > 0 else { return }
        let key = Self.key(text, target)
        lock.lock()
        defer { lock.unlock() }
        entries[key] = Entry(translation: outcome.translation, model: outcome.model, lastUsed: Date())
        if entries.count > 800 { // LRU 淘汰到 500
            let keep = entries.sorted { $0.value.lastUsed > $1.value.lastUsed }.prefix(500)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        persistLocked()
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        persistLocked()
    }

    private func persistLocked() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private static func key(_ text: String, _ target: String) -> String {
        target + "\u{1}" + text
    }
}
