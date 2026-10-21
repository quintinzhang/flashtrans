import AppKit

// FlashTrans（闪译）：GLM 划词翻译 + 本地翻译服务
// 菜单栏常驻（accessory），全局快捷键取词，鼠标旁弹窗显示译文，
// 同时在 127.0.0.1 提供 HTTP 翻译接口供终端 / 其他工具调用。
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
