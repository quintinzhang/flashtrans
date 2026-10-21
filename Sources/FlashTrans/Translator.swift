import Foundation

enum TranslationError: LocalizedError {
    case noAPIKey
    case http(Int, String)
    case emptyResponse
    case network(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "尚未配置 API Key：点菜单栏 FlashTrans 图标 → 设置…，填入智谱 API Key（open.bigmodel.cn 申请，flash 系模型有免费额度）"
        case .http(let code, let message):
            return "GLM 接口错误（HTTP \(code)）：\(message)"
        case .emptyResponse:
            return "GLM 返回内容为空，请重试或换个模型"
        case .network(let message):
            return "网络错误：\(message)"
        }
    }
}

struct TranslationOutcome {
    let translation: String
    let model: String
    let elapsedMs: Int
    var fromCache: Bool = false
}

/// GLM（智谱）OpenAI 兼容接口客户端。
///
/// 速度的两个来源（2026-10-21 实测）：
/// 1. 模型侧：glm-4.7-flashx + 关闭 thinking（翻译不需要推理），5s → 1.5s；
/// 2. 网络侧：Clash 对 bigmodel 链路转发质量差（~50% 超时；且 Clash 中 bigmodel
///    本就 DIRECT，白名单无效），用 DoH 解析真实 IP 后直连（DirectHTTPClient），
///    0.7~1.6s 稳定。直连失败时自动回退系统默认路径兜底。
enum Translator {
    private static let resolver = DoHResolver()

    static func translate(_ text: String, to target: String = "auto") async throws -> TranslationOutcome {
        guard let key = KeychainStore.get(), !key.isEmpty else { throw TranslationError.noAPIKey }

        // 命中本地缓存：零网络请求，瞬时返回
        if let cached = TranslationCache.shared.lookup(text, to: target) {
            return cached
        }

        let settings = AppSettings.shared
        guard let url = URL(string: settings.endpoint) else {
            throw TranslationError.http(-1, "接口地址不合法：\(settings.endpoint)")
        }

        let system: String
        switch target {
        case "zh":
            system = "你是翻译引擎。把用户输入翻译成简体中文。只输出译文本身，不要任何解释。"
        case "en":
            system = "You are a translation engine. Translate the user input into English. Output only the translation itself."
        default:
            system = "你是专业翻译引擎：若输入主要是中文，译成地道英文；否则译成简体中文。只输出译文本身，不要解释、不要重复原文。代码、命令、URL、专有名词保持原样。"
        }

        var body: [String: Any] = [
            "model": settings.model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": text],
            ],
            "temperature": 0.2,
            "stream": false,
        ]
        if settings.disableThinking {
            body["thinking"] = ["type": "disabled"]
        }

        let startedAt = Date()
        var result = await attempt(url: url, key: key, body: body)
        // 模型不支持关思考（错误码 1210，如 glm-5.3-flash「始终思考」）→ 去掉参数重试一次
        if case let .serverError(code, _, _) = result, code == "1210", settings.disableThinking {
            body.removeValue(forKey: "thinking")
            result = await attempt(url: url, key: key, body: body)
        }

        switch result {
        case .success(let data):
            let outcome = try decode(data: data, model: settings.model, startedAt: startedAt)
            TranslationCache.shared.store(outcome, text: text, to: target)
            return outcome
        case let .serverError(_, message, httpStatus):
            throw TranslationError.http(httpStatus, message)
        case .transport(let message):
            if Task.isCancelled { throw CancellationError() }
            throw TranslationError.network(message)
        case nil:
            if Task.isCancelled { throw CancellationError() }
            throw TranslationError.network("请求失败（直连与系统路径均未成功）")
        }
    }

    // MARK: - 请求路径

    /// 一轮完整尝试：直连真实 IP →（全失败时）回退系统默认网络栈。任务取消则立即退出。
    private static func attempt(url: URL, key: String, body: [String: Any]) async -> RawResult? {
        if Task.isCancelled { return nil }
        if AppSettings.shared.bypassProxy,
           let direct = await performViaDirectIP(url: url, key: key, body: body) {
            return direct
        }
        if Task.isCancelled { return nil }
        guard let request = buildRequest(url: url, key: key, body: body) else { return nil }
        return await send(request, session: URLSession.shared)
    }

    /// DoH 解析真实 IP，逐个尝试直连；第一轮失败强制重新解析再来一轮。
    private static func performViaDirectIP(url: URL, key: String, body: [String: Any]) async -> RawResult? {
        guard let host = url.host, !host.isEmpty else { return nil }
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        let headers = [
            "Content-Type": "application/json",
            "Authorization": "Bearer \(key)",
        ]
        for round in 0..<2 {
            if Task.isCancelled { return nil }
            let ips = await resolver.ips(for: host, refresh: round > 0)
            for ip in ips.prefix(2) {
                if Task.isCancelled { return nil }
                // 正常直连 0.7~1.6s；超过 3.5s 视为坏入口，尽快换下一个 IP
                guard let response = try? await DirectHTTPClient.shared.post(
                    url: url, ip: ip, headers: headers, body: payload, timeout: 3.5
                ) else { continue } // 连接被取消/失败都会走到这里，循环头的 isCancelled 检查负责停下
                if response.status == 200 {
                    resolver.markGood(host, ip: ip)
                    return .success(response.body)
                }
                let code = errorCode(from: response.body) ?? String(response.status)
                let message = errorMessage(from: response.body) ?? "未知错误"
                return .serverError(code: code, message: message, httpStatus: response.status)
            }
        }
        return nil
    }

    private static func buildRequest(url: URL, key: String, body: [String: Any]) -> URLRequest? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = data
        return request
    }

    private enum RawResult {
        case success(Data)
        case serverError(code: String, message: String, httpStatus: Int)
        case transport(String)
    }

    private static func send(_ request: URLRequest, session: URLSession) async -> RawResult? {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .transport(error.localizedDescription)
        }
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard statusCode == 200 else {
            let code = errorCode(from: data) ?? String(statusCode)
            let message = errorMessage(from: data) ?? "未知错误"
            return .serverError(code: code, message: message, httpStatus: statusCode)
        }
        return .success(data)
    }

    private static func decode(data: Data, model: String, startedAt: Date) throws -> TranslationOutcome {
        struct GLMResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message?
            }
            let choices: [Choice]?
        }
        guard let decoded = try? JSONDecoder().decode(GLMResponse.self, from: data) else {
            throw TranslationError.emptyResponse
        }
        var content = decoded.choices?.first?.message?.content ?? ""
        if let range = content.range(of: "</think>") { // 万一模型输出思考段，去掉
            content = String(content[range.upperBound...])
        }
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw TranslationError.emptyResponse }
        return TranslationOutcome(
            translation: content,
            model: model,
            elapsedMs: Int(Date().timeIntervalSince(startedAt) * 1000)
        )
    }

    private static func errorCode(from data: Data) -> String? {
        struct ErrorBody: Decodable {
            struct Detail: Decodable { let code: String? }
            let error: Detail?
        }
        return (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error?.code
    }

    private static func errorMessage(from data: Data) -> String? {
        struct ErrorBody: Decodable {
            struct Detail: Decodable {
                let code: String?
                let message: String?
            }
            let error: Detail?
        }
        guard let body = try? JSONDecoder().decode(ErrorBody.self, from: data),
              let detail = body.error else {
            return String(data: data.prefix(300), encoding: .utf8)
        }
        return [detail.code, detail.message].compactMap { $0 }.joined(separator: ": ")
    }
}

// MARK: - DoH 解析（绕过系统 DNS 的 fake-ip，也绕过 Clash 对 bigmodel 的劣质转发）

final class DoHResolver {
    private var cache: [String: (ips: [String], at: Date)] = [:]
    private let lock = NSLock()
    private static let providers = ["https://223.5.5.5/resolve", "https://120.53.53.53/resolve"]

    func ips(for host: String, refresh: Bool = false) async -> [String] {
        if !refresh {
            lock.lock()
            if let entry = cache[host], Date().timeIntervalSince(entry.at) < 300 {
                lock.unlock()
                return entry.ips
            }
            lock.unlock()
        }
        for base in Self.providers {
            if let list = await query(base: base, host: host), !list.isEmpty {
                lock.lock()
                cache[host] = (list, Date())
                lock.unlock()
                return list
            }
        }
        lock.lock()
        let cached = refresh ? [] : (cache[host]?.ips ?? [])
        lock.unlock()
        return cached
    }

    /// 把验证可用的 IP 提到列表首位
    func markGood(_ host: String, ip: String) {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = cache[host] else { return }
        entry.ips.removeAll { $0 == ip }
        entry.ips.insert(ip, at: 0)
        cache[host] = entry
    }

    private func query(base: String, host: String) async -> [String]? {
        guard let url = URL(string: "\(base)?name=\(host)&type=1") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = object["Answer"] as? [[String: Any]] else { return nil }
        let list = answers.compactMap { ($0["type"] as? Int) == 1 ? $0["data"] as? String : nil }
        return list.isEmpty ? nil : list
    }
}
