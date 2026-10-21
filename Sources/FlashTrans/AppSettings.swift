import Foundation

let flashTransVersion = "1.0"

/// 全局配置：持久化到 UserDefaults；API Key 只存钥匙串（见 KeychainStore）。
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    static let defaultEndpoint = "https://open.bigmodel.cn/api/paas/v4/chat/completions"

    private let defaults = UserDefaults.standard

    @Published var model: String { didSet { defaults.set(model, forKey: "model") } }
    @Published var endpoint: String { didSet { defaults.set(endpoint, forKey: "endpoint") } }
    @Published var port: Int { didSet { defaults.set(port, forKey: "port") } }
    @Published var autoCopy: Bool { didSet { defaults.set(autoCopy, forKey: "autoCopy") } }
    @Published var bypassProxy: Bool { didSet { defaults.set(bypassProxy, forKey: "bypassProxy") } }
    @Published var disableThinking: Bool { didSet { defaults.set(disableThinking, forKey: "disableThinking") } }
    @Published var hotkeyKeyCode: UInt32 { didSet {
        defaults.set(Int(hotkeyKeyCode), forKey: "hotkeyKeyCode")
        NotificationCenter.default.post(name: .flashTransHotkeyChanged, object: nil)
    } }
    @Published var hotkeyModifiers: UInt32 { didSet {
        defaults.set(Int(hotkeyModifiers), forKey: "hotkeyModifiers")
        NotificationCenter.default.post(name: .flashTransHotkeyChanged, object: nil)
    } }
    @Published var autoCloseSeconds: Int { didSet { defaults.set(autoCloseSeconds, forKey: "autoCloseSeconds") } }
    @Published var cacheDays: Int { didSet { defaults.set(cacheDays, forKey: "cacheDays") } }
    /// 注意：启动时不同步读钥匙串——新签名首次访问会触发系统授权等待，可能阻塞主线程导致服务起不来。
    /// didFinishLaunching 里在后台线程 refreshKeyStatus() 补上真实状态。
    @Published private(set) var keyConfigured: Bool = false

    private init() {
        let d = UserDefaults.standard
        model = d.string(forKey: "model") ?? "glm-4.7-flashx"
        endpoint = d.string(forKey: "endpoint") ?? Self.defaultEndpoint
        port = d.object(forKey: "port") as? Int ?? 8390
        autoCopy = d.bool(forKey: "autoCopy")
        bypassProxy = d.object(forKey: "bypassProxy") as? Bool ?? true
        disableThinking = d.object(forKey: "disableThinking") as? Bool ?? true
        // 默认 ⌥D（kVK_ANSI_D == 2，Carbon optionKey == 1 << 11）
        hotkeyKeyCode = UInt32(d.object(forKey: "hotkeyKeyCode") as? Int ?? 2)
        hotkeyModifiers = UInt32(d.object(forKey: "hotkeyModifiers") as? Int ?? (1 << 11))
        autoCloseSeconds = d.object(forKey: "autoCloseSeconds") as? Int ?? 0
        cacheDays = d.object(forKey: "cacheDays") as? Int ?? 30
    }

    func refreshKeyStatus() {
        keyConfigured = (KeychainStore.get()?.isEmpty == false)
    }

    func saveAPIKey(_ key: String) {
        try? KeychainStore.set(key)
        refreshKeyStatus()
    }
}

extension Notification.Name {
    static let flashTransHotkeyChanged = Notification.Name("flashTransHotkeyChanged")
}
