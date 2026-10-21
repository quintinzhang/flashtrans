# FlashTrans（闪译）

> macOS 系统级划词翻译 + 本地翻译服务，后端 GLM 极速版（智谱 bigmodel）。
> 在任何 App（终端 / 浏览器 / IDE / 微信…）里选中文字按 `⌥D`，译文在鼠标旁 1 秒左右弹出；同时提供 `127.0.0.1:8390` HTTP 翻译接口与 `glmtrans` 终端命令。

纯原生 Swift（SwiftPM，无第三方依赖），菜单栏常驻，需要 macOS 14+。本仓库是个人自用工具，也是一份「问题驱动开发」的完整记录——见下方 [开发里程碑](#-开发里程碑问题与解决思路)。

## ✨ 功能

- **划词翻译**：`⌥D`（可录制更换），鼠标旁弹窗，不抢焦点；Esc / 点击外部关闭
- **秒级响应**：`glm-4.7-flashx` + 关闭 thinking + 真实 IP 直连 + 本地缓存，中位耗时 ~1s，缓存命中 <0.05s
- **本地翻译服务**：`GET|POST /translate`、`GET /health`、`POST /set-key`，浏览器/脚本/扩展都能调
- **终端 CLI**：`glmtrans "hello"` / `echo 你好 | glmtrans` / 管道结合 git log 等
- **本地缓存**：相同「文本+目标语言」默认 30 天直接命中（可配置 0/7/30/90/365 天，LRU 上限 500 条）
- **细节**：弹窗可拖拽（系统级窗口拖动）、永不出屏、关窗即中止网络请求、翻译完可自动复制、开机自启

## 🚀 快速开始

```bash
git clone https://github.com/quintinzhang/flashtrans.git
cd flashtrans

# 1. 一次性：生成本地代码签名证书（保证重装后「辅助功能」授权不失效）
./scripts/setup-dev-cert.sh

# 2. 构建 + 签名 + 安装 /Applications + 装 CLI
./scripts/make-app.sh

# 3. 打开 App，按引导完成两步：
#    ① 系统设置 → 隐私与安全性 → 辅助功能 → 勾选 FlashTrans
#    ② 菜单栏 FlashTrans → 设置… → 填入智谱 API Key（https://open.bigmodel.cn → API Keys，flash 系模型有免费额度）
```

完成。选中任意文字按 `⌥D` 试试。

## 📖 使用

### 划词翻译

选中文字 → `⌥D` → 鼠标旁弹窗显示译文（中英自动互译）。弹窗标题栏可拖拽，译文可选中复制，一键「复制译文」。

### 终端

```bash
glmtrans "The quick brown fox"          # 中英自动互译
git log -1 --format=%s | glmtrans       # 管道输入
glmtrans --to zh "context deadline exceeded"
glmtrans --raw "hello"                  # 输出完整 JSON
glmtrans --set-key <KEY>                # 保存 API Key
glmtrans --health                       # 服务状态
```

### HTTP API（127.0.0.1:8390，仅本机）

```
GET  /health                    状态（模型、Key、辅助功能、版本）
GET  /translate?text=..&to=zh   翻译（to 可选 zh/en/auto）
POST /translate                 {"text":"...", "to":"auto"}
                                → {"translation":"...", "model":"...", "elapsed_ms":123, "cached":false}
POST /set-key                   {"api_key":"..."}   写入配置
DELETE /set-key                 删除 Key
```

错误返回 `{"error":"中文说明"}`；401=未配 Key，502=网络/上游错误。

## ⚙️ 配置（菜单栏 → 设置…）

| 项 | 默认 | 说明 |
|---|---|---|
| 模型 | `glm-4.7-flashx` | 秒级；`glm-5.3-flash` 质量更好但「始终思考」约 5s |
| 关闭深度思考 | 开 | 翻译无需推理，5s → 1.5s 的主要来源 |
| GLM 直连 | 开 | DoH 解析真实 IP 直连，绕开代理链路抖动（见 M3） |
| 缓存有效期 | 30 天 | 相同文本+目标语言命中本地缓存，瞬时返回 |
| 快捷键 | ⌥D | 可录制（需含 ⌘/⌥/⌃ 之一） |
| 端口 | 8390 | 占用时自动向后尝试 16 个 |

## 🏗️ 架构

```
Sources/FlashTrans/
  main.swift             入口（accessory 常驻）
  AppDelegate.swift      菜单栏 / 设置窗口 / 启动流程
  HotkeyManager.swift    Carbon RegisterEventHotKey 全局热键
  TextGrabber.swift      取词：AX 直读选中区 →（兜底）模拟 ⌘C + 剪贴板备份还原
  Translator.swift       GLM 客户端：缓存 → DoH+IP 直连 → 系统网络栈回退
  DirectHTTPClient.swift 手写 HTTP/1.1 over NWConnection（SNI+按域名校验，可取消）
  TranslationCache.swift 翻译缓存（JSON 持久化，LRU+天数过期）
  PopupController.swift  鼠标旁弹窗（NSPanel + SwiftUI，系统级拖动）
  LocalServer.swift      127.0.0.1 HTTP 服务（NWListener，手写协议解析）
  SettingsView.swift     设置界面（SwiftUI）
  AppSettings.swift      配置（UserDefaults）
scripts/
  setup-dev-cert.sh      一次性生成本地代码签名证书
  make-app.sh            构建 + 签名 + 安装
cli/glmtrans             终端 CLI（bash + curl + python3）
```

---

## 🚩 开发里程碑（问题与解决思路）

这个项目一天内从零到顺手，每一版都由一个具体问题驱动。记录在此，既是复盘也是后来者的避坑指南。

### M1 · 基础可用：全 App 取词是怎么做到的

**问题**：怎么在「任何 App」里拿到选中文字？

**思路**：两条路——
1. **辅助功能 API 直读**（`AXUIElementCopyAttributeValue` + `kAXSelectedTextAttribute`）：不碰剪贴板，快且无副作用；但部分 App（某些浏览器/自绘控件）不支持。
2. **模拟 ⌘C**：保存剪贴板全部类型 → `CGEvent` 合成 Cmd+C → 轮询 `changeCount` 读取 → 还原剪贴板。通吃几乎所有 App，但会短暂触碰用户剪贴板。

**解**：先走 ①，拿不到自动降级 ②。取词弹窗（borderless + `.nonactivatingPanel` NSPanel）不抢焦点，不打断当前操作。全局热键用 Carbon `RegisterEventHotKey`（能正确吞键、不需要轮询键盘）。

**Swift 桥接小坑**：Carbon 常量（`kEventParamDirectObject` 等）导入为 `Int`，需显式转 `UInt32`；`NSMenu.addItem` 要 `.separator()` 不是 `.separator`。

### M2 · 秒级翻译：瓶颈根本不在网络

**问题**：首版单次翻译 4~5 秒，还偶发 30 秒超时。

**排查**：先用 curl 对模型接口做矩阵实测——同一段话：
- `glm-5.3-flash`：~5.2s，且接口报错「该模型始终思考，不支持关闭思考」
- `glm-5.1-highspeed`：账号无权限；`glm-4-flash`：已下线
- `glm-4.7-flashx` + `thinking: {"type":"disabled"}`：**~1.5s**，`reasoning_content` 为空

**解**：默认模型切 `glm-4.7-flashx`，请求体带 `thinking disabled`（遇到不支持关思考的模型自动去掉该参数重试一次，代码 1210 处理）。**翻译不需要推理，5 秒里 3.5 秒是模型在"思考"**——这是最大单一优化项。

### M3 · 网络直连：和 Clash 的三回合拉锯（本项目的硬仗）

**问题**：换模型后仍偶发 20s+ 超时，且走 URLSession 的失败率约 30~50%。

**回合一 · 以为是代理问题**：给 URLSession 清空 `connectionProxyDictionary` 想绕开代理——没用，`dig` 一查，`open.bigmodel.cn` 解析到 **198.18.0.53**：这是 Clash **TUN 模式 fake-ip 段**，全部流量在网络层就被接管，「绕过代理设置」是绕不过 TUN 的。

**回合二 · Clash 白名单（被数据否决的方案）**：给 Clash 加 `DOMAIN-SUFFIX,bigmodel.cn,DIRECT` 规则。结果发现 Clash 规则里 bigmodel 本来就命中 `GeoSite CN → DIRECT`；对照实测走 Clash 的请求 **~50% 概率 12s 超时**（HTTP 代理和 TUN 两条路径都一样）——问题不在分流，在 Clash 对这条链路的转发质量本身。白名单方案作废，Clash 配置还原原状。

**回合三 · App 内直连真实 IP**：
- 用国内 DoH（`223.5.5.5` / `120.53.53.53`，纯 IP 的 HTTPS 查询，不经被劫持的系统 DNS）拿到真实入口 IP → curl `--resolve` 直连实测：**5/5 成功，0.7~1.6s**，路是通的。
- 但 URLSession 直连 IP 会失败：**它发不出 SNI**，TLS 握手被网关拒绝；即便握手（网关无 SNI 也下发 `*.bigmodel.cn` 通配证书），默认证书校验又拿 IP 当主机名必然失败。
- **解**：用 Network.framework 手写了一个 ~200 行的极简 HTTP/1.1 客户端（`DirectHTTPClient`）：
  - `sec_protocol_options_set_tls_server_name` 设 SNI = 真实域名
  - verify block 里 `SecPolicyCreateSSL(true, host)` **按域名校验**证书（不是 IP）
  - `Connection: close` 一次一连接，读完即关，不用实现连接池和 chunked 的复杂状态机（也实现了 chunked 解码兜底）
  - 每个入口 IP 3.5s 判死（正常直连 <1.6s），DoH 结果缓存 5 分钟，好 IP 提到队首
- 直连失败自动回退系统网络栈（走 Clash）兜底。**最终：中位 ~1s，成功率 9~10/10。**

> 复盘：用户最初要求「别为绕开 Clash 写复杂代码，除非有极速优化效果」。最终保留这套方案是因为数据达标（1s vs 2.6~12s + 50% 失败）——先做实验拿数据，再决定要不要为它写复杂代码。

### M4 · 权限稳定性：ad-hoc 签名的三连坑

**问题**：每次重新构建安装后，「辅助功能」勾选失效、钥匙串反复弹授权框、系统设置里出现重复条目。

**根因**：TCC（隐私权限）和钥匙串 ACL 都绑定 App 的**代码签名**。ad-hoc 签名每次构建都变，系统每次都认为是「新 App」。

**解**：
1. `scripts/setup-dev-cert.sh` 生成 10 年期自签代码签名证书（openssl + `security import`，注意 macOS 钥匙串不认 openssl 3 默认的 p12 算法，要加 `-legacy`），`make-app.sh` 优先用它签名——签名固定后，重装不再丢辅助功能授权。
2. 若历史多次安装已留下**多条死条目**（列表里勾着旧的、系统认的是新的），`tccutil reset Accessibility com.zq.flashtrans` 清光后重新勾选一次即愈。
3. 钥匙串授权弹窗：与其反复授权，翻译 Key 改存 UserDefaults（免费额度低风险，明文换清净）；`delete()` 顺手清理旧钥匙串条目。

**附带坑**：启动时**同步**读钥匙串，遇到授权等待会把主线程卡死、本地服务都起不来——改为后台异步读取。这也是「服务莫名起不来」的元凶之一；另一个是曾把「实际可用端口」回写配置，多实例切换期端口漂移到 8391 被永久记住——改为不回写。**调试手段**：`sample <pid>` 看主线程栈 + 关键路径写 `/tmp` 日志，两分钟定位。

### M5 · 交互打磨：拖拽、取消、缓存

**弹窗拖拽的两次尝试**：
1. SwiftUI `DragGesture` 手动 `setFrameOrigin`——不跟手、重影、抖动（手势回调异步派发 + 系统窗口阴影重绘滞后 + 亚像素坐标）。
2. **解**：改系统级窗口拖动（`isMovableByWindowBackground` + `NSHostingView` 子类放行 `mouseDownCanMoveWindow`），由窗口服务器直接处理，与拖普通窗口完全一致；系统阴影关掉，改 SwiftUI 内容自绘 `.shadow` 随内容整体移动；重排（译文到达高度变化时）保持当前 top-left，拖到哪就停在哪。

**关闭即取消**：弹窗隐藏/手动关闭/新翻译顶替 → `Task.cancel()`；URLSession 自动中止，`DirectHTTPClient` 用 `withTaskCancellationHandler`（onCancel → `connection.cancel()`，连接立刻断开），不再空等超时。用 `CancelFlag` 区分「超时主动断开」与「任务取消」。

**位置约束**：弹窗 clamp 有个反直觉 bug——`min(max(origin, minX), maxX - width)` 当弹窗比屏幕宽时上界小于下界，位置反而飞出屏幕。改为 `max(minX, maxX - width)` 兜底 + 译文 `lineLimit(14)` 限高，弹窗永远完整落在当前屏幕内。

**缓存**：相同「文本+目标语言」JSON 文件缓存（默认 30 天、LRU 500 条、命中 0 网络请求 <50ms 返回，弹窗角标 `缓存 ⚡`）。

## 📈 Roadmap

- [ ] 划词后自动朗读译文
- [ ] 多语言目标（日/韩/…）
- [ ] 译文流式输出（SSE）
- [ ] 历史记录面板
- [ ] 浏览器扩展（调本地服务）

## 📄 许可

[MIT](LICENSE) · 仅供学习与个人使用；使用前请自行确认智谱 open.bigmodel.cn 服务条款。
