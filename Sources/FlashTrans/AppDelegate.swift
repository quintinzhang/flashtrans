import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings.shared
    private let server = LocalServer.shared
    private var hotkey = HotkeyManager()
    private var statusItem: NSStatusItem?
    private var settingsWindow: SettingsWindowController?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        ftlog("didFinishLaunching 开始")
        let headless = CommandLine.arguments.contains("--no-ui")

        // 钥匙串状态在后台线程读：新签名首次访问可能触发系统授权弹窗，不能卡主线程
        DispatchQueue.global(qos: .utility).async {
            AppSettings.shared.refreshKeyStatus()
        }

        server.start(preferredPort: validPort(settings.port)) { [weak self] port in
            if let port {
                // 注意：不把实际端口回写配置——多实例切换期的临时占用（如 8391）会被永久记住，
                // 导致后续启动永远偏离用户配置的端口。
                ftlog("本地服务已启动 :\(port)")
                NSLog("[FlashTrans] 本地翻译服务已启动：http://127.0.0.1:%d", Int(port))
            } else {
                ftlog("本地服务启动失败（端口 \(self?.settings.port ?? 8390) 起 17 个端口均不可用）")
                NSLog("[FlashTrans] 警告：本地服务启动失败")
            }
        }
        ftlog("server.start 已调用, headless=\(headless)")

        guard !headless else { return }

        setupStatusItem()

        settings.$hotkeyKeyCode
            .combineLatest(settings.$hotkeyModifiers)
            .dropFirst()
            .sink { [weak self] keyCode, modifiers in
                self?.hotkey.update(keyCode: keyCode, modifiers: modifiers) {
                    PopupController.shared.showGrabAndTranslate()
                }
            }
            .store(in: &cancellables)
        hotkey.update(keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyModifiers) {
            PopupController.shared.showGrabAndTranslate()
        }

        if !TextGrabber.isTrusted,
           !UserDefaults.standard.bool(forKey: "accessibilityOnboardingDone") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.showAccessibilityOnboarding()
            }
        }
    }

    private func validPort(_ value: Int) -> UInt16 {
        (1024...65535).contains(value) ? UInt16(value) : 8390
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "FlashTrans")
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item
    }

    private func showAccessibilityOnboarding() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "启用划词翻译需要「辅助功能」权限"
        alert.informativeText = "请在 系统设置 → 隐私与安全性 → 辅助功能 中勾选 FlashTrans（若之前勾选过，请先取消再重新勾选），完成后即可用 \(HotkeyManager.display(keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyModifiers)) 划词翻译。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        UserDefaults.standard.set(true, forKey: "accessibilityOnboardingDone")
        if alert.runModal() == .alertFirstButtonReturn {
            TextGrabber.requestTrust()
        }
    }

    // MARK: - 菜单动作

    @objc private func translateNow() {
        PopupController.shared.showGrabAndTranslate()
    }

    @objc private func openSettingsAction() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController()
        }
        settingsWindow?.show()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            try AutoLauncher.set(!AutoLauncher.isEnabled)
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "设置登录项失败"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func requestAccessibilityAction() {
        TextGrabber.requestTrust()
    }

    @objc private func openServiceHealth() {
        if server.port != 0, let url = URL(string: "http://127.0.0.1:\(server.port)/health") {
            NSWorkspace.shared.open(url)
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let hotkeyLabel = HotkeyManager.display(keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyModifiers)
        menu.addItem(withTitle: "划词翻译 \(hotkeyLabel)", action: #selector(translateNow), keyEquivalent: "").target = self

        menu.addItem(.separator())
        menu.addItem(withTitle: "设置…", action: #selector(openSettingsAction), keyEquivalent: ",").target = self

        let launchItem = menu.addItem(withTitle: "开机自启", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = AutoLauncher.isEnabled ? .on : .off

        menu.addItem(withTitle: "辅助功能授权…", action: #selector(requestAccessibilityAction), keyEquivalent: "").target = self

        let serviceTitle = server.port == 0 ? "本地服务（未启动）" : "本地服务 \(server.portText)"
        menu.addItem(withTitle: serviceTitle, action: #selector(openServiceHealth), keyEquivalent: "").target = self
        menu.items.last?.isEnabled = server.port != 0

        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 FlashTrans", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }
}

/// 自管理的设置窗口：accessory 应用要正常收键盘输入（打字/粘贴/快捷键录制），
/// 打开时临时切到 regular 激活策略，关闭时切回 accessory（无 Dock 图标常驻）。
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let content = NSHostingView(rootView: SettingsView())
            let frame = NSRect(x: 0, y: 0, width: 560, height: 700)
            let newWindow = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            newWindow.title = "FlashTrans 设置"
            newWindow.contentView = content
            newWindow.isReleasedWhenClosed = false
            newWindow.delegate = self
            newWindow.center()
            window = newWindow
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // 部分系统版本上首次 activate 不生效，二次触发保证前台
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
