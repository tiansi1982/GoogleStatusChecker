import Foundation

/// The OpenAI ancillary hosts represent the concrete suffixes in the Clash
/// OpenAI provider. Keyword and suffix rules can match many more hostnames.
struct AgentEndpoint: Equatable, Sendable {
    enum Contract: String, Decodable, Sendable {
        case discovery, oauthToken, protectedAPI, claudeMetadata, claudeSignIn, releaseFile, httpsHost
    }

    let purpose: String
    let url: URL
    let contract: Contract
    let required: Bool

    init(_ purpose: String, _ address: String, _ contract: Contract, required: Bool = true) {
        self.purpose = purpose
        self.url = URL(string: "https://" + address)!
        self.contract = contract
        self.required = required
    }

    var method: String {
        switch contract {
        case .oauthToken, .protectedAPI: return "POST"
        case .discovery, .claudeMetadata: return "GET"
        case .claudeSignIn, .releaseFile, .httpsHost: return "HEAD"
        }
    }

    private struct Entry: Decodable {
        let purpose: String
        let address: String
        let contract: Contract
        let required: Bool
    }

    private static let catalog: [String: [Entry]] = {
        guard let url = Bundle.main.url(forResource: "AgentEndpoints", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([String: [Entry]].self, from: data),
              ServiceKind.allCases.allSatisfy({ entries[$0.rawValue]?.contains(where: \.required) == true }) else {
            preconditionFailure("Missing or invalid bundled AgentEndpoints.json")
        }
        return entries
    }()

    static func endpoints(for kind: ServiceKind) -> [Self] {
        catalog[kind.rawValue]!.map { Self($0.purpose, $0.address, $0.contract, required: $0.required) }
    }
}

struct AgentProbeResult: Equatable, Sendable {
    let endpoint: AgentEndpoint
    let state: CheckState
    let detail: String

    static func classify(_ endpoint: AgentEndpoint, status: Int, host: String?, data: Data,
                         location: URL?, challenged: Bool) -> Self {
        func result(_ state: CheckState, _ reason: String) -> Self {
            Self(endpoint: endpoint, state: state, detail: "\(reason) · HTTP \(status)")
        }
        guard host == endpoint.url.host else { return result(.unknown, "响应域名不符") }
        if challenged || ProbeClassifier.isCloudflareBlockPage(statusCode: status, data: data) {
            return result(.red, "遇到访问验证或拦截")
        }
        if [403, 429, 451].contains(status) { return result(.yellow, "探测请求受限") }
        if (500...599).contains(status) { return result(.red, "服务端异常") }
        if endpoint.contract == .releaseFile {
            return (200..<300).contains(status) ? result(.green, "版本文件可达") : result(.unknown, "未确认版本文件")
        }
        if endpoint.contract == .httpsHost {
            // A first-hop HTTP reply on this exact TLS host proves connectivity only.
            if status == 426 { return result(.green, "HTTPS 可达，服务要求升级协议") }
            if (200..<400).contains(status) || [400, 401, 404, 405].contains(status) {
                return result(.green, "HTTPS 可达")
            }
            return result(.unknown, "HTTP 响应异常")
        }
        if endpoint.contract == .claudeSignIn {
            guard (300...399).contains(status), location?.scheme == "https",
                  location?.host == "claude.ai", location?.path == "/oauth/authorize" else {
                return result(.unknown, "未确认登录跳转")
            }
            return result(.green, "登录跳转正常")
        }
        guard data.count <= maxProbeBodyBytes,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return result(.unknown, "未收到预期 JSON")
        }
        let error = json["error"] as? [String: Any]
        switch endpoint.contract {
        case .discovery:
            if status == 200, let issuer = json["issuer"] as? String,
               let url = URL(string: issuer), url.scheme == "https", url.host == host,
               json["token_endpoint"] is String { return result(.green, "登录服务可达") }
        case .oauthToken:
            let code = json["error"] as? String ?? error?["type"] as? String
            if status == 400, ["invalid_request", "invalid_request_error", "unsupported_grant_type"].contains(code) {
                return result(.green, "令牌服务可达")
            }
        case .protectedAPI:
            let type = error?["type"] as? String
            let detail = json["detail"] as? String
            if status == 401, error?["status"] as? String == "UNAUTHENTICATED"
                || ["invalid_request_error", "authentication_error"].contains(type)
                || detail?.lowercased() == "unauthorized" {
                return result(.green, "接口已响应鉴权")
            }
        case .claudeMetadata:
            if status == 200, json["client_id"] is String, json["redirect_uris"] is [String] {
                return result(.green, "登录配置可达")
            }
        case .claudeSignIn, .releaseFile, .httpsHost: break
        }
        return result(.unknown, "响应与接口预期不符")
    }
}

extension ServiceReport {
    func including(_ results: [AgentProbeResult]) -> ServiceReport {
        let required = results.filter { $0.endpoint.required }
        let failures = required.filter { $0.state != .green }
        let priority: [CheckState] = [.red, .yellow, .unknown, .checking, .green]
        let worst = priority.first { candidate in state == candidate || failures.contains { $0.state == candidate } } ?? state
        let issue = failures.first { $0.state == worst } ?? failures.first
        let summary = issue.map { "\($0.endpoint.purpose)：\($0.detail)" } ?? "关键地址 \(required.count)/\(required.count) 可达"
        return ServiceReport(kind: kind, state: worst, detail: "\(detail) · \(summary)", exitIP: exitIP, endpoints: results)
    }
}
