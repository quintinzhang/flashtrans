import ServiceManagement
import SwiftUI

/// 快捷键录制器：捕获下一个「带 ⌘/⌥/⌃ 的组合键」。
final class HotkeyRecorder: ObservableObject {
    @Published var isRecording = false
    private var monitor: Any?

    func toggle(onSet: @escaping (UInt32, UInt32) -> Void) {
        if isRecording {
            stop()
            return
        }
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Esc 取消
                self.stop()
                return event
            }
            let modifiers = HotkeyManager.carbonModifiers(from: event.modifierFlags)
            guard modifiers != 0 else { return event }
            onSet(UInt32(event.keyCode), modifiers)
            self.stop()
            return nil
        }
    }

    func stop() {
        if let local = monitor {
            NSEvent.removeMonitor(local)
        }
        monitor = nil
        isRecording = false
    }
}

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var recorder = HotkeyRecorder()
    @State private var keyInput = ""
    @State private var keyMessage: String?
    @State private var launchAtLogin = AutoLauncher.isEnabled
    @State private var cacheCount = TranslationCache.shared.count
    @FocusState private var keyFieldFocused: Bool

    private let presets = ["glm-4.7-flashx", "glm-4.5-flash", "glm-4.5-air", "glm-5.3-flash"]

    var body: some View {
        Form {
            Section("GLM 接入") {
                keySection
                modelSection
                endpointSection
            }
            Section("取词快捷键") {
                hotkeySection
            }
            Section("弹窗与剪贴板") {
                behaviorSection
            }
            Section("本地翻译服务") {
                serverSection
            }
            Section("翻译缓存") {
                Picker("缓存有效期", selection: $settings.cacheDays) {
                    Text("关闭").tag(0)
                    Text("7 天").tag(7)
                    Text("30 天").tag(30)
                    Text("90 天").tag(90)
                    Text("一年").tag(365)
                }
                HStack {
                    Text("当前缓存 \(cacheCount) 条（上限 500，超出自动淘汰最久未用）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("清空缓存") {
                        TranslationCache.shared.clear()
                        cacheCount = TranslationCache.shared.count
                    }
                    .controlSize(.small)
                }
                Text("相同「文本 + 目标语言」30 天内直接命中本地缓存，零网络请求、瞬时返回（弹窗右上角显示「缓存 ⚡」）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("登录项") {
                Toggle("登录时自动启动 FlashTrans", isOn: $launchAtLogin)
            }
            Section("首次使用") {
                helpSection
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 540, minHeight: 680)
        .onChange(of: launchAtLogin) { _, enabled in
            do {
                try AutoLauncher.set(enabled)
            } catch {
                launchAtLogin = AutoLauncher.isEnabled
            }
        }
        .onDisappear {
            recorder.stop()
        }
    }

    // MARK: - 各区块

    private var keySection: some View {
        Group {
            SecureField("API Key（本地存储）", text: $keyInput, prompt: Text(settings.keyConfigured ? "已保存，输入可覆盖" : "粘贴或输入智谱 API Key"))
                .focused($keyFieldFocused)
                .onAppear {
                    if !settings.keyConfigured {
                        keyFieldFocused = true
                    }
                }
            HStack {
                Button("从剪贴板粘贴") {
                    if let text = NSPasteboard.general.string(forType: .string) {
                        keyInput = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                .controlSize(.small)
                Button("保存") {
                    let trimmed = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    settings.saveAPIKey(trimmed)
                    keyInput = ""
                    keyMessage = settings.keyConfigured ? "已保存 ✓" : "保存失败，请重试"
                }
                .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                if settings.keyConfigured {
                    Label("已配置", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Button("删除") {
                        KeychainStore.delete()
                        settings.refreshKeyStatus()
                    }
                    .controlSize(.small)
                } else {
                    Label("未配置", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
                if let keyMessage {
                    Text(keyMessage).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack {
                Text("还没有 Key？")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("去 open.bigmodel.cn 申请（flash 系模型有免费额度）",
                     destination: URL(string: "https://open.bigmodel.cn/usercenter/apikeys")!)
                    .font(.caption)
            }
        }
    }

    private var modelSection: some View {
        Group {
            Picker("预设模型", selection: presetBinding) {
                Text("glm-4.7-flashx（推荐 · 秒级）").tag("glm-4.7-flashx")
                Text("glm-4.5-flash").tag("glm-4.5-flash")
                Text("glm-4.5-air").tag("glm-4.5-air")
                Text("glm-5.3-flash（质量好但始终思考，约 5 秒）").tag("glm-5.3-flash")
                Text("自定义…").tag("custom")
            }
            TextField("模型名", text: $settings.model)
            Toggle("关闭模型深度思考（更快）", isOn: $settings.disableThinking)
            Text("翻译不需要推理：关掉思考约 5s → 1~1.5s。个别「始终思考」模型（如 glm-5.3-flash）会自动忽略此开关。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("GLM 请求直连（不走系统代理 / Clash）", isOn: $settings.bypassProxy)
            Text("bigmodel.cn 是国内服务，直连比经代理中转更快更稳；对 Clash 配置零改动。若以后换成海外端点连不上，再关闭此项改走系统代理。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var presetBinding: Binding<String> {
        Binding(
            get: { presets.contains(settings.model) ? settings.model : "custom" },
            set: { selection in
                if selection != "custom" {
                    settings.model = selection
                }
            }
        )
    }

    private var endpointSection: some View {
        Group {
            TextField("接口地址（OpenAI 兼容 chat/completions）", text: $settings.endpoint)
            HStack {
                Button("恢复默认") {
                    settings.endpoint = AppSettings.defaultEndpoint
                }
                .controlSize(.small)
                Text(settings.endpoint == AppSettings.defaultEndpoint ? "" : "已自定义")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var hotkeySection: some View {
        Group {
            HStack {
                Text("当前")
                Text(HotkeyManager.display(keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyModifiers))
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
                Spacer()
                Button(recorder.isRecording ? "按新组合键…（Esc 取消）" : "录制") {
                    recorder.toggle { keyCode, modifiers in
                        settings.hotkeyKeyCode = keyCode
                        settings.hotkeyModifiers = modifiers
                    }
                }
            }
            Text("组合键需至少包含 ⌘ / ⌥ / ⌃ 之一，更改立即生效。默认 ⌥D。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var behaviorSection: some View {
        Group {
            Toggle("翻译完成后自动复制译文", isOn: $settings.autoCopy)
            Picker("弹窗自动关闭", selection: $settings.autoCloseSeconds) {
                Text("手动关闭").tag(0)
                Text("5 秒后").tag(5)
                Text("10 秒后").tag(10)
                Text("30 秒后").tag(30)
            }
        }
    }

    private var serverSection: some View {
        Group {
            HStack {
                Text("服务地址")
                Spacer()
                Text(LocalServer.shared.portText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("本地服务端口")
                Spacer()
                Text("\(settings.port)").monospacedDigit()
                Stepper("", value: $settings.port, in: 1024...65535)
                    .labelsHidden()
            }
            Text("端口改动重启 app 后生效；被占用时自动向后尝试 16 个。终端用法：glmtrans \"hello\"，或 curl http://127.0.0.1:\(settings.port)/translate")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var helpSection: some View {
        Group {
            HStack {
                Button("打开「辅助功能」授权设置") {
                    TextGrabber.requestTrust()
                }
                .controlSize(.small)
                Text("辅助功能状态：\(TextGrabber.isTrusted ? "✅ 已授权" : "❌ 未授权")")
                    .font(.caption)
                    .foregroundStyle(TextGrabber.isTrusted ? .green : .red)
            }
            Text("划词翻译用法：任意 app 里选中文字，按 \(HotkeyManager.display(keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyModifiers))，译文在鼠标旁弹出。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
