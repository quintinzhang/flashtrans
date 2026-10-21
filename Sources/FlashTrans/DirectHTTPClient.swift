import Foundation
import Network
import Security

/// 极简直连 HTTP/1.1 客户端（Network.framework）。
///
/// 背景（2026-10-21 实测）：本机 Clash 对 bigmodel 链路转发质量差（走 Clash 的请求
/// ~50% 概率 12s 超时，成功也要 2.6~8s；且 Clash 里 bigmodel 本来就是 DIRECT，
/// 白名单无效）。DoH 解析真实 IP 后直连，实测 0 失败、0.7~1.6s。
///
/// 为什么不用 URLSession 直连 IP：它发不出 SNI（TLS 握手被网关拒绝）。
/// NWConnection 可以显式设置 SNI = 真实域名、按域名校验证书；
/// 请求用 HTTP/1.1 + Connection: close（一次一连接，无需池化/chunked 复杂度）。
final class DirectHTTPClient {
    static let shared = DirectHTTPClient()
    private let queue = DispatchQueue(label: "flashtrans.direct.http", qos: .userInitiated)

    struct Response {
        let status: Int
        let body: Data
    }

    enum HTTPError: Error, LocalizedError {
        case badResponse
        case timeout

        var errorDescription: String? {
            switch self {
            case .badResponse: return "网关响应无法解析"
            case .timeout: return "连接超时"
            }
        }
    }

    /// 发送 POST。URL 提供域名/端口/路径；ip 是 DoH 解析出的真实入口 IP。
    func post(url: URL, ip: String, headers: [String: String], body: Data, timeout: TimeInterval = 8) async throws -> Response {
        try await perform(method: "POST", url: url, ip: ip, headers: headers, body: body, timeout: timeout)
    }

    // MARK: - 内部

    private func perform(method: String, url: URL, ip: String, headers: [String: String], body: Data?, timeout: TimeInterval) async throws -> Response {
        guard let host = url.host, !host.isEmpty else { throw HTTPError.badResponse }
        let port = UInt16(url.port ?? 443)
        var target = url.path.isEmpty ? "/" : url.path
        if let query = url.query { target += "?\(query)" }

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let tlsOptions = NWProtocolTLS.Options()
        // SNI = 真实域名（URLSession 直连 IP 做不到，这是握手失败的主因）
        sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, host)
        // 证书按真实域名校验（连接目标是 IP，默认校验必失败）
        let verify: sec_protocol_verify_t = { _, secTrust, complete in
            let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
            let policy = SecPolicyCreateSSL(true, host as CFString)
            SecTrustSetPolicies(trust, policy)
            complete(SecTrustEvaluateWithError(trust, nil))
        }
        sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, verify, queue)

        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        let connection = NWConnection(
            host: NWEndpoint.Host(ip),
            port: NWEndpoint.Port(rawValue: port)!,
            using: parameters
        )
        let timeoutFlag = CancelFlag()
        defer { connection.cancel() }

        // 任务取消（弹窗关闭等）→ connection.cancel() → 各 await 抛错，不再空等超时
        return try await withTaskCancellationHandler {
            // 超时兜底：主动 cancel 连接，stateUpdateHandler 的 .cancelled 分支会抛错
            queue.asyncAfter(deadline: .now() + timeout) {
                timeoutFlag.markTimedOut()
                connection.cancel()
            }

            // 建连
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let coordinator = ResumeCoordinator(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        coordinator.resume()
                    case .failed(let error):
                        coordinator.resume(throwing: error)
                    case .cancelled:
                        coordinator.resume(throwing: timeoutFlag.isTimedOut ? HTTPError.timeout : CancellationError())
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }

            // 组包
            var request = "\(method) \(target) HTTP/1.1\r\n"
            var allHeaders = headers
            allHeaders["Host"] = host
            allHeaders["Connection"] = "close"
            if let body { allHeaders["Content-Length"] = String(body.count) }
            for (key, value) in allHeaders {
                request += "\(key): \(value)\r\n"
            }
            request += "\r\n"
            var payload = Data(request.utf8)
            if let body { payload.append(body) }

            // 发送
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: payload, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
            }

            // 读到连接关闭（Connection: close，body 完整后服务器断开）
            var buffer = Data()
            while true {
                let (chunk, complete) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data?, Bool), Error>) in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: (data, isComplete))
                        }
                    }
                }
                if let chunk { buffer.append(chunk) }
                if complete || buffer.count > 5_000_000 { break }
            }

            guard let response = Self.parse(buffer) else { throw HTTPError.badResponse }
            return response
        } onCancel: {
            connection.cancel()
        }
    }

    /// 解析 HTTP/1.1 响应（支持 Content-Length 与 chunked）
    static func parse(_ raw: Data) -> Response? {
        guard let headerRange = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = raw.subdata(in: 0..<headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        var lines = headerText.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }

        var lowercasedHeaders: [String: String] = [:]
        for line in lines {
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                lowercasedHeaders[key] = value
            }
        }

        let bodyStart = headerRange.upperBound
        let rawBody = raw.subdata(in: bodyStart..<raw.endIndex)
        let body: Data
        if lowercasedHeaders["transfer-encoding"]?.contains("chunked") == true {
            body = Self.decodeChunked(rawBody) ?? rawBody
        } else if let length = Int(lowercasedHeaders["content-length"] ?? ""), length <= rawBody.count {
            body = rawBody.subdata(in: rawBody.startIndex..<rawBody.startIndex + length)
        } else {
            body = rawBody
        }
        return Response(status: status, body: body)
    }

    private static func decodeChunked(_ data: Data) -> Data? {
        var decoded = Data()
        var cursor = data.startIndex
        while cursor < data.endIndex {
            guard let lineEnd = data.range(of: Data("\r\n".utf8), in: cursor..<data.endIndex) else { return nil }
            let sizeLine = String(data: data.subdata(in: cursor..<lineEnd.lowerBound), encoding: .utf8) ?? ""
            let hex = sizeLine.split(separator: ";").first.map(String.init) ?? sizeLine
            guard let size = Int(hex.trimmingCharacters(in: .whitespaces), radix: 16) else { return nil }
            cursor = lineEnd.upperBound
            if size == 0 { break }
            let chunkEnd = data.index(cursor, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
            decoded.append(data.subdata(in: cursor..<chunkEnd))
            cursor = chunkEnd
            if data.distance(from: cursor, to: data.endIndex) >= 2 {
                cursor = data.index(cursor, offsetBy: 2)
            }
        }
        return decoded
    }
}

/// 区分「超时主动断开」与「任务取消」的线程安全标志
final class CancelFlag {
    private let lock = NSLock()
    private var timedOut = false

    func markTimedOut() {
        lock.lock()
        defer { lock.unlock() }
        timedOut = true
    }

    var isTimedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }
}

/// 保证 continuation 只 resume 一次（stateUpdateHandler 可能多次回调）
private final class ResumeCoordinator {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var resumed = false

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume() {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation?.resume()
        continuation = nil
    }

    func resume(throwing error: Error) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
