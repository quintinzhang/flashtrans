import Foundation
import Network

/// 调试日志（排查启动问题用，写 /tmp/flashtrans-debug.log）
func ftlog(_ message: String) {
    let line = "\(Date()) \(message)\n"
    let url = URL(fileURLWithPath: "/tmp/flashtrans-debug.log")
    let data = Data(line.utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        try? handle.write(contentsOf: data)
    } else {
        try? data.write(to: url)
    }
}

/// 极简 HTTP 请求解析（够用即可：支持 Content-Length 定长的 POST）。
struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    init?(_ data: Data) {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data.subdata(in: 0..<headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8), !headerText.isEmpty else { return nil }

        var lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        method = parts[0].uppercased()

        let target = String(parts[1])
        var parsedPath = target
        var parsedQuery: [String: String] = [:]
        if let questionMark = target.firstIndex(of: "?") {
            parsedPath = String(target[..<questionMark])
            for pair in target[target.index(after: questionMark)...].split(separator: "&") {
                let keyValue = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let key = String(keyValue[0]).removingPercentEncoding else { continue }
                let rawValue = keyValue.count > 1 ? String(keyValue[1]) : ""
                let value = (rawValue.removingPercentEncoding ?? rawValue).replacingOccurrences(of: "+", with: " ")
                parsedQuery[key] = value
            }
        }

        var parsedHeaders: [String: String] = [:]
        for line in lines {
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                parsedHeaders[key] = value
            }
        }

        let contentLength = Int(parsedHeaders["content-length"] ?? "0") ?? 0
        let bodyStart = headerRange.upperBound
        guard contentLength >= 0, contentLength <= 1_500_000,
              data.count - bodyStart >= contentLength else { return nil }
        body = data.subdata(in: bodyStart..<bodyStart + contentLength)
        path = parsedPath
        query = parsedQuery
        headers = parsedHeaders
    }

    func jsonObject() -> Any? {
        guard !body.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: body)
    }
}

/// 本地翻译服务：只监听 127.0.0.1，供终端 curl / glmtrans / 浏览器扩展调用。
final class LocalServer {
    static let shared = LocalServer()

    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private var basePort: UInt16 = 8390

    var portText: String { port == 0 ? "未启动" : "http://127.0.0.1:\(port)" }

    func start(preferredPort: UInt16, completion: ((UInt16?) -> Void)? = nil) {
        basePort = preferredPort
        ftlog("LocalServer.start preferredPort=\(preferredPort)")
        attempt(preferredPort, completion)
    }

    private func attempt(_ candidate: UInt16, _ completion: ((UInt16?) -> Void)?) {
        guard candidate >= basePort, candidate - basePort < 17 else {
            ftlog("LocalServer 放弃：候选 \(candidate) 超出范围")
            completion?(nil)
            return
        }
        ftlog("LocalServer.attempt 绑定 127.0.0.1:\(candidate)")
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: candidate)!
        )
        let newListener: NWListener
        do {
            newListener = try NWListener(using: parameters)
        } catch {
            ftlog("LocalServer NWListener 创建失败 \(candidate): \(error)")
            attempt(candidate &+ 1, completion)
            return
        }
        newListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            switch state {
            case .ready:
                guard let self, let newListener else { return }
                self.listener = newListener
                self.port = candidate
                ftlog("LocalServer ready :\(candidate)")
                completion?(candidate)
            case .failed(let error):
                ftlog("LocalServer failed \(candidate): \(error)")
                newListener?.cancel()
                self?.attempt(candidate &+ 1, completion)
            case .cancelled:
                ftlog("LocalServer cancelled \(candidate)")
            default:
                ftlog("LocalServer state \(candidate): \(String(describing: state))")
            }
        }
        newListener.start(queue: DispatchQueue(label: "flashtrans.server.\(candidate)", qos: .userInitiated))
    }

    // MARK: - 连接处理

    private func accept(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "flashtrans.conn", qos: .userInitiated))
        read(connection, Data())
    }

    private func read(_ connection: NWConnection, _ accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] chunk, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = accumulated
            if let chunk { buffer.append(chunk) }
            if buffer.count > 2_000_000 {
                self.respond(connection, status: 413, body: ["error": "请求过大"])
                return
            }
            if let request = HTTPRequest(buffer) {
                self.route(request, connection)
            } else if isComplete || error != nil {
                if buffer.isEmpty {
                    connection.cancel()
                } else {
                    self.respond(connection, status: 400, body: ["error": "无法解析 HTTP 请求"])
                }
            } else {
                self.read(connection, buffer)
            }
        }
    }

    // MARK: - 路由

    private func route(_ request: HTTPRequest, _ connection: NWConnection) {
        if request.method == "OPTIONS" {
            respond(connection, status: 204, body: [:])
            return
        }
        switch (request.method, request.path) {
        case ("GET", "/health"):
            respond(connection, status: 200, body: [
                "status": "ok",
                "version": flashTransVersion,
                "model": AppSettings.shared.model,
                "endpoint": AppSettings.shared.endpoint,
                "key_configured": KeychainStore.get() != nil,
                "accessibility": TextGrabber.isTrusted,
                "port": Int(port),
            ])
        case ("GET", "/translate"), ("POST", "/translate"):
            translate(request, connection)
        case ("POST", "/set-key"):
            guard let object = request.jsonObject() as? [String: Any],
                  let key = object["api_key"] as? String,
                  !key.trimmingCharacters(in: .whitespaces).isEmpty else {
                respond(connection, status: 400, body: ["error": "缺少 api_key 字段"])
                return
            }
            do {
                try KeychainStore.set(key.trimmingCharacters(in: .whitespaces))
                AppSettings.shared.refreshKeyStatus()
                respond(connection, status: 200, body: ["status": "saved"])
            } catch {
                respond(connection, status: 500, body: ["error": error.localizedDescription])
            }
        case ("DELETE", "/set-key"):
            KeychainStore.delete()
            AppSettings.shared.refreshKeyStatus()
            respond(connection, status: 200, body: ["status": "deleted"])
        default:
            respond(connection, status: 404, body: [
                "error": "not found",
                "hint": "GET /health · GET|POST /translate · POST|DELETE /set-key",
            ])
        }
    }

    private func translate(_ request: HTTPRequest, _ connection: NWConnection) {
        var text = ""
        var target = "auto"
        if let object = request.jsonObject() as? [String: Any] {
            text = (object["text"] as? String) ?? ""
            if let to = object["to"] as? String { target = to }
        }
        if text.isEmpty { text = request.query["text"] ?? "" }
        if request.method == "GET", let to = request.query["to"] { target = to }

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            respond(connection, status: 400, body: ["error": "缺少 text：POST {\"text\":\"...\"} 或 GET ?text="])
            return
        }
        if text.count > 8000 {
            text = String(text.prefix(8000)) + " …（过长已截断）"
        }

        Task {
            do {
                let outcome = try await Translator.translate(text, to: target)
                self.respond(connection, status: 200, body: [
                    "translation": outcome.translation,
                    "model": outcome.model,
                    "elapsed_ms": outcome.elapsedMs,
                    "cached": outcome.fromCache,
                ])
            } catch {
                let message = (error as? TranslationError)?.errorDescription ?? error.localizedDescription
                let status: Int
                if case TranslationError.noAPIKey = error {
                    status = 401
                } else if case let TranslationError.http(code, _) = error {
                    status = (400..<600).contains(code) ? code : 502
                } else {
                    status = 502
                }
                self.respond(connection, status: status, body: ["error": message])
            }
        }
    }

    private func respond(_ connection: NWConnection, status: Int, body: [String: Any]) {
        let payload = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        let reason = Self.statusReason[status] ?? "OK"
        let header = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: application/json; charset=utf-8\r\n"
            + "Content-Length: \(payload.count)\r\n"
            + "Connection: close\r\n"
            + "Access-Control-Allow-Origin: *\r\n"
            + "Access-Control-Allow-Methods: GET, POST, DELETE, OPTIONS\r\n"
            + "Access-Control-Allow-Headers: Content-Type\r\n\r\n"
        connection.send(content: Data(header.utf8) + payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static let statusReason: [Int: String] = [
        200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized",
        404: "Not Found", 413: "Payload Too Large", 500: "Internal Server Error",
        502: "Bad Gateway",
    ]
}
