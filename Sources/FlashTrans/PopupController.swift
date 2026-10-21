import AppKit
import Combine
import SwiftUI

final class PopupModel: ObservableObject {
    enum Phase {
        case loading
        case done(translation: String, model: String, elapsedMs: Int, fromCache: Bool)
        case failed(String)
        case info(title: String, message: String)
    }
    @Published var source: String = ""
    @Published var phase: Phase = .loading
    @Published var copied = false
}

/// 鼠标旁的翻译弹窗（不抢焦点，Esc / 点击面板外关闭）。
final class PopupController {
    static let shared = PopupController()

    private let model = PopupModel()
    private var panel: PopupPanel?
    /// 弹窗初始左上角锚点（show 时取鼠标旁）；后续重排保持当前位置（含拖拽后）
    private var anchor = NSPoint(x: 0, y: 0)
    private var translationTask: Task<Void, Never>?
    private var outsideMonitor: Any?
    private var relayoutCancellable: Any?
    private var autoHideTask: Task<Void, Never>?

    private init() {
        relayoutCancellable = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.relayout() }
        }
    }

    func showGrabAndTranslate() {
        guard TextGrabber.isTrusted else {
            showInfo(title: "需要「辅助功能」权限",
                     message: "请在 系统设置 → 隐私与安全性 → 辅助功能 中勾选 FlashTrans，然后重试。")
            return
        }
        guard let text = TextGrabber.grabSelectedText() else {
            showInfo(title: "未取到选中文本",
                     message: "请先用鼠标选中一段文字再按快捷键（密码框等安全输入区域不支持取词）。")
            return
        }
        translate(text)
    }

    func translate(_ text: String) {
        cancelTranslation() // 上一条还在跑就立即中止（含网络请求）
        model.source = text
        model.phase = .loading
        model.copied = false
        show()
        let popupModel = model
        translationTask = Task { @MainActor in
            do {
                let outcome = try await Translator.translate(text)
                guard !Task.isCancelled else { return }
                popupModel.phase = .done(translation: outcome.translation, model: outcome.model, elapsedMs: outcome.elapsedMs, fromCache: outcome.fromCache)
                if AppSettings.shared.autoCopy { self.copyCurrent() }
                self.scheduleAutoHide()
            } catch is CancellationError {
                // 弹窗已关闭/新请求顶替，静默退出
            } catch {
                guard !Task.isCancelled else { return }
                popupModel.phase = .failed(error.localizedDescription)
            }
        }
    }

    func showInfo(title: String, message: String) {
        cancelTranslation()
        model.source = ""
        model.phase = .info(title: title, message: message)
        show()
    }

    /// 取消进行中的翻译（hide / 新翻译 / 提示弹窗都会调用，及时断开网络请求）
    private func cancelTranslation() {
        translationTask?.cancel()
        translationTask = nil
    }

    func hide() {
        cancelTranslation() // 点外部/手动关闭 = 放弃本次翻译，立即中止 API 访问
        autoHideTask?.cancel()
        autoHideTask = nil
        if let monitor = outsideMonitor {
            NSEvent.removeMonitor(monitor)
            outsideMonitor = nil
        }
        panel?.orderOut(nil)
    }

    func copyCurrent() {
        if case .done(let translation, _, _, _) = model.phase {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(translation, forType: .string)
            model.copied = true
        }
    }

    // MARK: - 面板管理

    private func show() {
        let popup = ensurePanel()
        let mouse = NSEvent.mouseLocation
        anchor = NSPoint(x: mouse.x + 14, y: mouse.y - 12) // 弹窗左上角：鼠标右下方
        popup.orderFrontRegardless()
        popup.makeKey()
        relayout(initial: true)
        installOutsideMonitor()
    }

    private func ensurePanel() -> PopupPanel {
        if let existing = panel { return existing }
        let popup = PopupPanel()
        let hosting = PopupHostingView(rootView: PopupView(
            model: model,
            onCopy: { [weak self] in self?.copyCurrent() },
            onClose: { [weak self] in self?.hide() }
        ))
        popup.contentView = hosting
        panel = popup
        return popup
    }

    /// 位置约束在屏幕可视区内（弹窗超出屏幕大小时至少保证左/下边缘可见）
    static func clamp(origin: NSPoint, size: NSSize, visible: NSRect) -> NSPoint {
        let minX = visible.minX + 4
        let maxX = visible.maxX - 4
        let minY = visible.minY + 4
        let maxY = visible.maxY - 4
        var point = origin
        point.x = min(max(point.x, minX), max(minX, maxX - size.width))
        point.y = min(max(point.y, minY), max(minY, maxY - size.height))
        return point
    }

    /// initial=true 用鼠标旁锚点定位；否则保持当前 top-left（拖去哪译文来了也不跳）
    private func relayout(initial: Bool = false) {
        guard let popup = panel, popup.isVisible, let hosting = popup.contentView else { return }
        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        size.width = max(size.width, 260)
        size.height = min(max(size.height, 80), 600) // 超长译文限高，保证屏幕内放得下
        let topLeft: NSPoint
        if initial || popup.frame.width == 0 {
            topLeft = anchor
        } else {
            topLeft = NSPoint(x: popup.frame.minX, y: popup.frame.maxY)
        }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let origin = Self.clamp(origin: NSPoint(x: topLeft.x, y: topLeft.y - size.height), size: size, visible: visible)
        popup.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func installOutsideMonitor() {
        guard outsideMonitor == nil else { return }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return }
            if event.type == .keyDown {
                let bare = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if event.keyCode == 53 && bare.isEmpty { // Esc
                    self.hide()
                }
            } else {
                self.hide()
            }
        }
    }

    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        let seconds = AppSettings.shared.autoCloseSeconds
        guard seconds > 0 else { return }
        autoHideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            if !Task.isCancelled {
                await MainActor.run { self?.hide() }
            }
        }
    }
}

/// 系统「点击背景拖动窗口」直接可用的 HostingView（SwiftUI 非交互区域不拦截 mouseDown）
final class PopupHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
}

final class PopupPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        // 系统窗口阴影在快速拖动时会重绘滞后产生残影，改用 SwiftUI 内容自带阴影（见 PopupView）
        hasShadow = false
        isReleasedWhenClosed = false
        // 拖动交给窗口服务器处理（PopupHostingView 放行 mouseDownCanMoveWindow）：
        // 跟手程度与拖普通窗口一致，无 SwiftUI 手势的延迟/重影
        isMovableByWindowBackground = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
}

struct PopupView: View {
    @ObservedObject var model: PopupModel
    let onCopy: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Image(systemName: "character.bubble")
                    .foregroundStyle(.secondary)
                Text("FlashTrans")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                headerTrailing
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }
            .onHover { hovering in
                if hovering {
                    NSCursor.closedHand.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            Divider()
            if !model.source.isEmpty {
                Text(model.source)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: 440, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 12, x: 0, y: 4) // 随内容移动，拖动无残影
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.quaternary, lineWidth: 1))
        .padding(8)
        .onExitCommand { onClose() }
    }

    @ViewBuilder private var headerTrailing: some View {
        switch model.phase {
        case .done(_, let model, let elapsedMs, let fromCache):
            if fromCache {
                Text("\(model) · 缓存 ⚡").font(.caption2).foregroundStyle(.tertiary)
            } else {
                Text("\(model) · \(elapsedMs)ms").font(.caption2).foregroundStyle(.tertiary)
            }
        case .loading:
            Text("翻译中…").font(.caption2).foregroundStyle(.tertiary)
        case .failed:
            Text("失败").font(.caption2).foregroundStyle(.red)
        case .info:
            EmptyView()
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在调用 GLM …").font(.callout).foregroundStyle(.secondary)
            }
        case .done(let translation, _, _, _):
            VStack(alignment: .leading, spacing: 8) {
                Text(translation)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .lineLimit(14) // 限高，保证弹窗在屏幕内放得下
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(model.copied ? "已复制 ✓" : "复制译文") { onCopy() }
                        .controlSize(.small)
                        .disabled(model.copied)
                    Spacer()
                }
            }
        case .failed(let message):
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
        case .info(let title, let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
