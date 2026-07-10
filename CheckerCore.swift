import Foundation

enum CheckState: Hashable, Sendable {
    case green
    case yellow
    case red
    case unknown
    case checking

    var label: String {
        switch self {
        case .green: return "绿灯 - Google 可访问，出口地区为美国"
        case .yellow: return "黄灯 - Google 可访问，出口地区不是美国"
        case .red: return "红灯 - 无法访问 Google"
        case .unknown: return "蓝灯 - Google 可访问，出口地区未知"
        case .checking: return "检测中..."
        }
    }
}

struct CheckReport: Equatable, Sendable {
    let state: CheckState
    let detail: String

    static let checking = CheckReport(state: .checking, detail: "正在检测 Google 连通性")
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

enum ProbeClassifier {
    static func googleIsReachable(statusCode: Int, finalHost: String?) -> Bool {
        guard statusCode == 204, let finalHost = finalHost else { return false }
        return HostValidation.host(finalHost, belongsTo: "google.com")
    }

    static func countryCode(fromCloudflareTrace data: Data) -> String? {
        guard data.count <= 64 * 1024,
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

    static func report(forCountryCode countryCode: String) -> CheckReport {
        let normalized = countryCode.uppercased()
        if normalized == "XX" {
            return CheckReport(state: .unknown, detail: "Google 可访问；出口地区未知")
        }
        if normalized == "US" {
            return CheckReport(state: .green, detail: "Google 可访问；出口地区估算：美国（US）")
        }
        return CheckReport(state: .yellow, detail: "Google 可访问；出口地区估算：\(normalized)")
    }
}
