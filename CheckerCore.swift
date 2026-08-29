import Foundation

/// Upper bound applied to every probe response body before parsing.
let maxProbeBodyBytes = 64 * 1024

enum CheckState: Hashable, Sendable {
    case green
    case yellow
    case red
    case unknown
    case checking

    var symbol: String {
        switch self {
        case .green: return "🟢"
        case .yellow: return "🟡"
        case .red: return "🔴"
        case .unknown: return "🔵"
        case .checking: return "⚪"
        }
    }

    var summary: String {
        switch self {
        case .green: return "美国出口"
        case .yellow: return "非美国或受限"
        case .red: return "不可用"
        case .unknown: return "无法确认"
        case .checking: return "检测中"
        }
    }
}

enum ServiceKind: String, CaseIterable, Sendable {
    case google
    case chatgpt
    case claude

    var displayName: String {
        switch self {
        case .google: return "Google"
        case .chatgpt: return "ChatGPT"
        case .claude: return "Claude"
        }
    }
}

struct ServiceReport: Equatable, Sendable {
    let kind: ServiceKind
    let state: CheckState
    let detail: String

    init(kind: ServiceKind, state: CheckState, detail: String) {
        self.kind = kind
        self.state = state
        self.detail = detail
    }

    static func checking(_ kind: ServiceKind) -> ServiceReport {
        ServiceReport(kind: kind, state: .checking, detail: "正在检测 \(kind.displayName) 连通性")
    }

    var title: String { "\(kind.displayName)：\(state.symbol) \(state.summary)" }
}

enum OverallStatus {
    /// Single-light aggregation: green only when every service is green;
    /// any restricted, failed, or unknown service turns the light yellow.
    static func state(of reports: [ServiceReport], isChecking: Bool) -> CheckState {
        if isChecking { return .checking }
        guard reports.count == ServiceKind.allCases.count,
              Set(reports.map(\.kind)) == Set(ServiceKind.allCases) else {
            return .checking
        }
        return reports.allSatisfy { $0.state == .green } ? .green : .yellow
    }
}

enum HostValidation {
    /// Returns true only when `host` is `domain` itself or a real subdomain of it.
    /// A string contains check is deliberately avoided so that domains such as
    /// `notgoogle.com` and `google.com.example.org` are rejected.
    static func host(_ host: String, belongsTo domain: String) -> Bool {
        let normalizedHost = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let normalizedDomain = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalizedHost == normalizedDomain || normalizedHost.hasSuffix("." + normalizedDomain)
    }
}

/// Static description of an AI API probe target (called without credentials).
struct APIProbe: Sendable {
    let zoneDomain: String
    /// JSON error code that marks an unsupported-region rejection, if the API defines one.
    let regionErrorCode: String?

    static let openAI = APIProbe(
        zoneDomain: "openai.com",
        regionErrorCode: "unsupported_country_region_territory"
    )
    static let anthropic = APIProbe(zoneDomain: "anthropic.com", regionErrorCode: nil)
}

enum CloudflareEdgeOutcome: Equatable, Sendable {
    case reachable(countryCode: String?)
    case blocked
    case unexpected(String)
}

enum APIRegionOutcome: Equatable, Sendable {
    case available
    case regionRestricted(reason: String)
    case blocked
    case connectionFailed(String)
    case unexpected(String)
}

/// Extracts the `error` object shared by OpenAI- and Anthropic-style JSON error bodies.
struct APIErrorBody: Equatable, Sendable {
    let hasErrorObject: Bool
    let errorCode: String?
    let errorType: String?
    let errorMessage: String?

    init(parsing data: Data) {
        guard data.count <= maxProbeBodyBytes,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let error = object["error"] as? [String: Any] else {
            hasErrorObject = false
            errorCode = nil
            errorType = nil
            errorMessage = nil
            return
        }
        hasErrorObject = true
        errorCode = error["code"] as? String
        errorType = error["type"] as? String
        errorMessage = error["message"] as? String
    }
}

enum ProbeClassifier {
    static func googleIsReachable(statusCode: Int, finalHost: String?) -> Bool {
        guard statusCode == 204, let finalHost = finalHost else { return false }
        return HostValidation.host(finalHost, belongsTo: "google.com")
    }

    static func countryCode(fromCloudflareTrace data: Data) -> String? {
        guard data.count <= maxProbeBodyBytes,
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let parts = rawLine.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == "loc" else {
                continue
            }

            let code = parts[1].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard code.count == 2, code.unicodeScalars.allSatisfy({ scalar in
                scalar.value >= 65 && scalar.value <= 90
            }) else {
                return nil
            }
            return code
        }
        return nil
    }

    /// Recognizes Cloudflare WAF block and managed-challenge pages. Only HTTP error
    /// responses are considered; markers are matched case-insensitively.
    static func isCloudflareBlockPage(statusCode: Int, data: Data) -> Bool {
        guard (400...599).contains(statusCode),
              data.count <= maxProbeBodyBytes,
              let text = String(data: data, encoding: .utf8) else {
            return false
        }
        let lowered = text.lowercased()
        return lowered.contains("sorry, you have been blocked")
            || lowered.contains("just a moment")
            || lowered.contains("attention required")
            || lowered.contains("cf-chl")
            || lowered.contains("cf-error-details")
            || lowered.contains("enable javascript and cookies")
    }

    /// Classifies a `cdn-cgi/trace` request against a Cloudflare-fronted web property.
    static func classifyEdge(
        statusCode: Int,
        finalHost: String?,
        data: Data,
        zoneDomain: String
    ) -> CloudflareEdgeOutcome {
        if isCloudflareBlockPage(statusCode: statusCode, data: data) {
            return .blocked
        }
        guard statusCode == 200 else {
            // A 403/451 denial without a recognizable page is still a zone-level rejection.
            if statusCode == 403 || statusCode == 451 {
                return .blocked
            }
            return .unexpected("HTTP \(statusCode)")
        }
        guard let host = finalHost, HostValidation.host(host, belongsTo: zoneDomain) else {
            return .unexpected("请求落到了非预期域名 \(finalHost ?? "未知")")
        }
        return .reachable(countryCode: countryCode(fromCloudflareTrace: data))
    }

    /// Classifies an unauthenticated API call used as a region/availability probe:
    /// an auth error means the API answered and did not reject the region.
    static func classifyAPI(
        statusCode: Int,
        finalHost: String?,
        data: Data,
        probe: APIProbe
    ) -> APIRegionOutcome {
        guard let host = finalHost, HostValidation.host(host, belongsTo: probe.zoneDomain) else {
            return .unexpected("请求落到了非预期域名 \(finalHost ?? "未知")")
        }

        let body = APIErrorBody(parsing: data)

        switch statusCode {
        case 200..<300:
            return .available
        case 401:
            return body.hasErrorObject ? .available : .unexpected("HTTP 401（非标准 API 响应）")
        case 403, 451:
            if let code = body.errorCode, code == probe.regionErrorCode {
                return .regionRestricted(reason: "服务不支持当前出口地区")
            }
            if isCloudflareBlockPage(statusCode: statusCode, data: data) {
                return .blocked
            }
            return .regionRestricted(reason: denialReason(body: body, statusCode: statusCode))
        default:
            if isCloudflareBlockPage(statusCode: statusCode, data: data) {
                return .blocked
            }
            return .unexpected("HTTP \(statusCode)")
        }
    }

    private static func denialReason(body: APIErrorBody, statusCode: Int) -> String {
        if let code = body.errorCode {
            return "API 拒绝了请求：错误码 \(code)（HTTP \(statusCode)）"
        }
        if let type = body.errorType {
            return "API 拒绝了请求：错误类型 \(type)（HTTP \(statusCode)）"
        }
        return "API 拒绝了请求（HTTP \(statusCode)）"
    }

    static func regionDisplay(_ code: String?) -> String {
        guard let normalized = code?.uppercased(), !normalized.isEmpty, normalized != "XX" else {
            return "未知"
        }
        return normalized
    }

    // MARK: - Report builders

    static func googleReport(forCountryCode countryCode: String) -> ServiceReport {
        let normalized = countryCode.uppercased()
        if normalized == "XX" {
            return ServiceReport(
                kind: .google,
                state: .unknown,
                detail: "Google 可访问；Cloudflare 辅助探测无法确认出口地区"
            )
        }
        if normalized == "US" {
            return ServiceReport(
                kind: .google,
                state: .green,
                detail: "Google 可访问；Cloudflare 辅助探测出口：美国（US）"
            )
        }
        return ServiceReport(
            kind: .google,
            state: .yellow,
            detail: "Google 可访问；Cloudflare 辅助探测出口不是美国：\(normalized)"
        )
    }

    static func edgeBlockedReport(kind: ServiceKind) -> ServiceReport {
        ServiceReport(
            kind: kind,
            state: .red,
            detail: "\(kind.displayName) 网页入口被 Cloudflare 拦截或拒绝（IP 疑似被风控或地区封锁）"
        )
    }

    static func edgeUnexpectedReport(kind: ServiceKind, reason: String) -> ServiceReport {
        ServiceReport(
            kind: kind,
            state: .unknown,
            detail: "\(kind.displayName) 网页入口响应异常：\(reason)"
        )
    }

    static func aiReport(
        kind: ServiceKind,
        edgeCountry: String?,
        api: APIRegionOutcome
    ) -> ServiceReport {
        let region = regionDisplay(edgeCountry)
        switch api {
        case .available:
            guard region != "未知" else {
                return ServiceReport(
                    kind: kind,
                    state: .unknown,
                    detail: "\(kind.displayName) 服务与 API 入口可达，但无法确认出口地区"
                )
            }
            guard region == "US" else {
                return ServiceReport(
                    kind: kind,
                    state: .yellow,
                    detail: "\(kind.displayName) 服务与 API 入口可达，但出口地区不是美国：\(region)"
                )
            }
            return ServiceReport(
                kind: kind,
                state: .green,
                detail: "\(kind.displayName) 服务与 API 入口可达；出口地区：美国（US）"
            )
        case .regionRestricted(let reason):
            return ServiceReport(
                kind: kind,
                state: .yellow,
                detail: "\(kind.displayName) 服务入口可达，但\(reason)；出口地区：\(region)"
            )
        case .blocked:
            return ServiceReport(
                kind: kind,
                state: .red,
                detail: "\(kind.displayName) 服务入口可达，但 API 被 Cloudflare 拦截（IP 疑似被风控）"
            )
        case .connectionFailed(let error):
            return ServiceReport(
                kind: kind,
                state: .red,
                detail: "\(kind.displayName) 服务入口可达，但 API 连接失败：\(error)；出口地区：\(region)"
            )
        case .unexpected(let reason):
            return ServiceReport(
                kind: kind,
                state: .unknown,
                detail: "\(kind.displayName) 服务入口可达；API 响应异常：\(reason)"
            )
        }
    }
}
