import Foundation

private extension APIRegionOutcome {
    var isRegionRestricted: Bool {
        if case .regionRestricted = self { return true }
        return false
    }

    var isUnexpected: Bool {
        if case .unexpected = self { return true }
        return false
    }
}

private struct TestFailure: Error {
    let message: String
}

@main
@MainActor
struct CheckerCoreTests {
    private static var testCount = 0

    static func main() throws {
        try testHostValidation()
        try testGoogleProbeClassification()
        try testCountryCodeParsing()
        try testGoogleReportClassification()
        try testCloudflareBlockPageDetection()
        try testEdgeClassification()
        try testOpenAIAPIClassification()
        try testAnthropicAPIClassification()
        try testAIReportBuilding()
        try testOverallAggregation()
        try testExitIPObservations()
        try testExitIPHistory()
        try testClaudeIPFamilies()
        try testAgentProbes()
        print("CheckerCoreTests: \(testCount) assertions passed")
    }

    private static func testHostValidation() throws {
        try expect(HostValidation.host("google.com", belongsTo: "google.com"))
        try expect(HostValidation.host("www.google.com", belongsTo: "google.com"))
        try expect(HostValidation.host("WWW.GOOGLE.COM.", belongsTo: "google.com"))
        try expect(!HostValidation.host("notgoogle.com", belongsTo: "google.com"))
        try expect(!HostValidation.host("google.com.example.org", belongsTo: "google.com"))
        try expect(!HostValidation.host("google.example.org", belongsTo: "google.com"))
    }

    private static func testGoogleProbeClassification() throws {
        try expect(ProbeClassifier.googleIsReachable(statusCode: 204, finalHost: "www.google.com"))
        try expect(!ProbeClassifier.googleIsReachable(statusCode: 200, finalHost: "www.google.com"))
        try expect(!ProbeClassifier.googleIsReachable(statusCode: 204, finalHost: "notgoogle.com"))
        try expect(!ProbeClassifier.googleIsReachable(statusCode: 204, finalHost: nil))
    }

    private static func testCountryCodeParsing() throws {
        let usTrace = Data("ip=192.0.2.1\nloc=US\ntls=TLSv1.3\n".utf8)
        let lowercaseTrace = Data("colo=nrt\nloc=jp\n".utf8)
        let malformedTrace = Data("loc=USA\n".utf8)
        let missingTrace = Data("colo=SJC\n".utf8)

        try expectEqual(CloudflareTrace(data: usTrace).countryCode, "US")
        try expectEqual(CloudflareTrace(data: lowercaseTrace).countryCode, "JP")
        try expectEqual(CloudflareTrace(data: malformedTrace).countryCode, nil)
        try expectEqual(CloudflareTrace(data: missingTrace).countryCode, nil)
        try expectEqual(CloudflareTrace(data: Data([0xFF])).countryCode, nil)
        try expectEqual(
            CloudflareTrace(data: Data(repeating: 65, count: maxProbeBodyBytes + 1)).countryCode,
            nil
        )
    }

    private static func testGoogleReportClassification() throws {
        try expectEqual(ProbeClassifier.googleReport(forCountryCode: "us").state, .green)
        try expectEqual(ProbeClassifier.googleReport(forCountryCode: "JP").state, .yellow)
        try expectEqual(ProbeClassifier.googleReport(forCountryCode: "XX").state, .unknown)
    }

    private static func testCloudflareBlockPageDetection() throws {
        let blockPage = Data("<html><title>Sorry, you have been blocked</title></html>".utf8)
        let challengePage = Data("<html>Just a moment...</html><script src='/cdn-cgi/challenge-platform/c/chl'></script>".utf8)
        let plainError = Data("Internal Server Error".utf8)

        try expect(ProbeClassifier.isCloudflareBlockPage(statusCode: 403, data: blockPage))
        try expect(ProbeClassifier.isCloudflareBlockPage(statusCode: 503, data: challengePage))
        try expect(!ProbeClassifier.isCloudflareBlockPage(statusCode: 200, data: blockPage))
        try expect(!ProbeClassifier.isCloudflareBlockPage(statusCode: 500, data: plainError))
        try expect(!ProbeClassifier.isCloudflareBlockPage(statusCode: 403, data: Data([0xFF])))
    }

    private static func testEdgeClassification() throws {
        let usTrace = Data("ip=192.0.2.1\nloc=US\n".utf8)
        let noLocTrace = Data("colo=LAX\n".utf8)
        let blockPage = Data("<html>Sorry, you have been blocked</html>".utf8)

        try expectEqual(
            ProbeClassifier.classifyEdge(
                statusCode: 200, finalHost: "chatgpt.com", data: usTrace, zoneDomain: "chatgpt.com"
            ),
            CloudflareEdgeOutcome.reachable(CloudflareTrace(data: usTrace))
        )
        try expectEqual(
            ProbeClassifier.classifyEdge(
                statusCode: 200, finalHost: "claude.ai", data: noLocTrace, zoneDomain: "claude.ai"
            ),
            CloudflareEdgeOutcome.reachable(CloudflareTrace(data: noLocTrace))
        )
        try expectEqual(
            ProbeClassifier.classifyEdge(
                statusCode: 403, finalHost: "chatgpt.com", data: blockPage, zoneDomain: "chatgpt.com"
            ),
            CloudflareEdgeOutcome.blocked
        )
        try expectEqual(
            ProbeClassifier.classifyEdge(
                statusCode: 403, finalHost: "claude.ai", data: Data("denied".utf8), zoneDomain: "claude.ai"
            ),
            CloudflareEdgeOutcome.blocked
        )
        try expectEqual(
            ProbeClassifier.classifyEdge(
                statusCode: 500, finalHost: "chatgpt.com", data: Data("oops".utf8), zoneDomain: "chatgpt.com"
            ),
            CloudflareEdgeOutcome.unexpected("HTTP 500")
        )
        try expectEqual(
            ProbeClassifier.classifyEdge(
                statusCode: 200, finalHost: "evil.com", data: usTrace, zoneDomain: "chatgpt.com"
            ),
            CloudflareEdgeOutcome.unexpected("请求落到了非预期域名 evil.com")
        )
    }

    private static func testOpenAIAPIClassification() throws {
        // Real response observed from api.openai.com without credentials.
        let missingAuth = Data(#"{"error":{"message":"Missing bearer authentication in header","type":"invalid_request_error","param":null,"code":null}}"#.utf8)
        try expectEqual(
            ProbeClassifier.classifyAPI(
                statusCode: 401, finalHost: "api.openai.com", data: missingAuth, probe: .openAI
            ),
            APIRegionOutcome.available
        )

        let regionBlocked = Data(#"{"error":{"message":"You must be a member of an organization...","type":"invalid_request_error","param":null,"code":"unsupported_country_region_territory"}}"#.utf8)
        try expectEqual(
            ProbeClassifier.classifyAPI(
                statusCode: 403, finalHost: "api.openai.com", data: regionBlocked, probe: .openAI
            ),
            APIRegionOutcome.regionRestricted(reason: "服务不支持当前出口地区")
        )

        let blockPage = Data("<html>Sorry, you have been blocked</html>".utf8)
        try expectEqual(
            ProbeClassifier.classifyAPI(
                statusCode: 403, finalHost: "api.openai.com", data: blockPage, probe: .openAI
            ),
            APIRegionOutcome.blocked
        )

        try expect(
            ProbeClassifier.classifyAPI(
                statusCode: 403, finalHost: "api.openai.com",
                data: Data(#"{"error":{"type":"permission_error"}}"#.utf8), probe: .openAI
            ).isRegionRestricted
        )
        try expect(
            ProbeClassifier.classifyAPI(
                statusCode: 401, finalHost: "api.openai.com",
                data: Data("<html>gateway</html>".utf8), probe: .openAI
            ).isUnexpected
        )
        try expect(
            ProbeClassifier.classifyAPI(
                statusCode: 500, finalHost: "api.openai.com", data: Data("oops".utf8), probe: .openAI
            ).isUnexpected
        )
        try expect(
            ProbeClassifier.classifyAPI(
                statusCode: 401, finalHost: "openai.com.evil.io", data: missingAuth, probe: .openAI
            ).isUnexpected
        )
    }

    private static func testAnthropicAPIClassification() throws {
        // Real response observed from api.anthropic.com without credentials.
        let missingKey = Data(#"{"type":"error","error":{"type":"authentication_error","message":"x-api-key header is required"},"request_id":"req_123"}"#.utf8)
        try expectEqual(
            ProbeClassifier.classifyAPI(
                statusCode: 401, finalHost: "api.anthropic.com", data: missingKey, probe: .anthropic
            ),
            APIRegionOutcome.available
        )

        try expect(
            ProbeClassifier.classifyAPI(
                statusCode: 403, finalHost: "api.anthropic.com",
                data: Data(#"{"type":"error","error":{"type":"permission_error","message":"Request not allowed"}}"#.utf8),
                probe: .anthropic
            ).isRegionRestricted
        )

        let challengePage = Data("<html>Just a moment...</html>".utf8)
        try expectEqual(
            ProbeClassifier.classifyAPI(
                statusCode: 403, finalHost: "api.anthropic.com", data: challengePage, probe: .anthropic
            ),
            APIRegionOutcome.blocked
        )
    }

    private static func testAIReportBuilding() throws {
        try expectEqual(
            ProbeClassifier.aiReport(kind: .chatgpt, edgeCountry: "US", api: .available).state,
            .green
        )
        try expectEqual(
            ProbeClassifier.aiReport(kind: .claude, edgeCountry: "us", api: .available).state,
            .green
        )
        try expectEqual(
            ProbeClassifier.aiReport(kind: .chatgpt, edgeCountry: "JP", api: .available).state,
            .yellow
        )
        try expectEqual(
            ProbeClassifier.aiReport(kind: .claude, edgeCountry: "DE", api: .available).state,
            .yellow
        )
        try expectEqual(
            ProbeClassifier.aiReport(kind: .chatgpt, edgeCountry: nil, api: .available).state,
            .unknown
        )
        try expectEqual(
            ProbeClassifier.aiReport(kind: .claude, edgeCountry: "XX", api: .available).state,
            .unknown
        )
        let nonUS = ProbeClassifier.aiReport(kind: .chatgpt, edgeCountry: "JP", api: .available)
        try expect(nonUS.detail.contains("出口地区不是美国：JP"))
        try expectEqual(
            ProbeClassifier.aiReport(
                kind: .chatgpt, edgeCountry: "US",
                api: .regionRestricted(reason: "服务不支持当前出口地区")
            ).state,
            .yellow
        )
        try expectEqual(
            ProbeClassifier.aiReport(kind: .claude, edgeCountry: nil, api: .blocked).state,
            .red
        )
        try expectEqual(
            ProbeClassifier.aiReport(kind: .claude, edgeCountry: "JP", api: .connectionFailed("超时")).state,
            .red
        )
        let apiDown = ProbeClassifier.aiReport(kind: .claude, edgeCountry: "jp", api: .connectionFailed("超时"))
        try expect(apiDown.detail.contains("JP"))
        try expectEqual(
            ProbeClassifier.aiReport(kind: .claude, edgeCountry: nil, api: .unexpected("HTTP 500")).state,
            .unknown
        )
        try expectEqual(ProbeClassifier.edgeBlockedReport(kind: .chatgpt).state, .red)
        try expectEqual(ProbeClassifier.edgeUnexpectedReport(kind: .chatgpt, reason: "HTTP 500").state, .unknown)
        try expectEqual(ServiceReport.checking(.claude).state, .checking)
    }

    private static func testOverallAggregation() throws {
        func report(_ kind: ServiceKind, _ state: CheckState) -> ServiceReport {
            ServiceReport(kind: kind, state: state, detail: "")
        }

        let allGreen = [report(.google, .green), report(.chatgpt, .green), report(.claude, .green)]
        try expectEqual(OverallStatus.state(of: allGreen, isChecking: false), .green)

        let actualReportsWithNonUSExit = [
            ProbeClassifier.googleReport(forCountryCode: "US"),
            ProbeClassifier.aiReport(kind: .chatgpt, edgeCountry: "JP", api: .available),
            ProbeClassifier.aiReport(kind: .claude, edgeCountry: "US", api: .available),
        ]
        try expectEqual(
            OverallStatus.state(of: actualReportsWithNonUSExit, isChecking: false),
            .yellow
        )

        // Any single problem turns the light yellow, regardless of its own state.
        try expectEqual(
            OverallStatus.state(
                of: [report(.google, .green), report(.chatgpt, .green), report(.claude, .yellow)],
                isChecking: false
            ),
            .yellow
        )
        try expectEqual(
            OverallStatus.state(
                of: [report(.google, .green), report(.chatgpt, .red), report(.claude, .green)],
                isChecking: false
            ),
            .yellow
        )
        try expectEqual(
            OverallStatus.state(
                of: [report(.google, .unknown), report(.chatgpt, .green), report(.claude, .green)],
                isChecking: false
            ),
            .yellow
        )

        try expectEqual(OverallStatus.state(of: allGreen, isChecking: true), .checking)
        try expectEqual(OverallStatus.state(of: [report(.google, .green)], isChecking: false), .checking)
    }

    private static func testExitIPObservations() throws {
        func trace(_ text: String) -> CloudflareTrace { CloudflareTrace(data: Data(text.utf8)) }
        let ipv6 = trace("loc=US\nip= 2001:0DB8:0:0:0:0:0:1 \n")
        try expectEqual(ipv6.ipAddress, "2001:db8::1")
        try expectEqual(ipv6.ipAddress, trace("ip=2001:db8::1").ipAddress)
        try expectEqual(trace("ip=203.0.113.7\r\nloc=??").ipAddress, "203.0.113.7")
        for bad in ["", "256.9.2.1", "garbage", "127.0.0.1\u{0}suffix", "2001:db8:::1"] {
            try expectEqual(trace("loc=US\nip=" + bad).ipAddress, nil)
        }
        try expectEqual(trace("ip=192.0.2.1\n" + String(repeating: "x", count: maxProbeBodyBytes)).ipAddress, nil)
        try expectEqual(ProbeClassifier.googleReport(forCountryCode: nil, exitIP: ipv6.ipAddress).exitIP, ipv6.ipAddress)
        try expectEqual(
            ProbeClassifier.aiReport(kind: .claude, edgeCountry: nil, api: .connectionFailed("超时"),
                                     exitIP: ipv6.ipAddress).exitIP, ipv6.ipAddress
        )
    }

    private static func testExitIPHistory() throws {
        let start = Date(timeIntervalSince1970: 12345)
        var history = ExitIPHistory()
        func observe(_ kind: ServiceKind, _ address: String?, _ seconds: Int) {
            let report = ServiceReport(kind: kind, state: .unknown, detail: "", exitIP: address)
            history.observe(report, at: start.addingTimeInterval(Double(seconds)))
        }

        observe(.google, "192.0.2.1", 0)
        observe(.claude, "192.0.2.2", 0)
        observe(.google, nil, 1)
        try expectEqual(history.records[.google]?.lastSeen, start)
        observe(.google, "192.0.2.1", 2)
        try expectEqual(history.records[.google]?.changes, [])
        try expectEqual(history.unreadServices, [])
        try expectEqual(history.records[.google]?.lastSeen, start.addingTimeInterval(2))

        observe(.google, "192.0.2.2", 3)
        observe(.google, nil, 4)
        let change = ExitIPChange(date: start.addingTimeInterval(3), previous: "192.0.2.1", current: "192.0.2.2")
        try expectEqual(history.records[.google]?.changes, [change])
        try expectEqual(history.unreadServices, [.google])
        observe(.claude, "2001:db8::1", 5)
        try expectEqual(history.unreadServices, [.google])
        observe(.claude, "2001:db8::2", 6)
        try expectEqual(history.unreadServices, [.google, .claude])

        // Use a disposable suite to keep test observations out of the app's preferences.
        let suite = "CheckerCoreTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        history.save(to: defaults)
        history = ExitIPHistory.load(from: defaults)
        try expectEqual(history.records[.google]?.changes, [change])
        try expectEqual(history.unreadServices, [.google, .claude])
        history.markAllRead()
        history.save(to: defaults)
        history = ExitIPHistory.load(from: defaults)
        try expectEqual(history.unreadServices, [])
        try expectEqual(history.records[.google]?.changes, [change])
        observe(.google, "192.0.2.1", 6)
        try expectEqual(history.unreadServices, [.google])
        try expectEqual(history.records[.google]?.changes.first?.previous, "192.0.2.2")
        for i in 1...60 { observe(.claude, "203.0.113.\(i)", i + 6) }
        try expectEqual(history.records[.claude]?.changes.count, ExitIPHistory.changesPerService)
        try expectEqual(history.records[.claude]?.changes.first?.current, "203.0.113.60")
        try expectEqual(history.records[.google]?.changes.count, 2)
    }

    private static func testClaudeIPFamilies() throws {
        let suite = "ClaudeIPFamilies." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = "192.0.2.1", b = "192.0.2.2", x = "2001:db8::1", y = "2001:db8::2"
        // The oldest retained event is the only evidence of the IPv4 baseline.
        let legacy = #"{"records":["claude",{"address":"2001:db8::1","lastSeen":1,"hasUnreadChange":true,"changes":[{"date":1,"previous":"192.0.2.1","current":"2001:db8::1"}]}]}"#
        defaults.set(Data(legacy.utf8), forKey: "exitIPHistory.v1")
        var history = ExitIPHistory.load(from: defaults)
        func observe(_ ip: String?) {
            history.observe(ServiceReport(kind: .claude, state: .green, detail: "", exitIP: ip), at: Date())
        }
        try expectEqual(history.records[.claude]?.familyBaselines?.ipv4, a)
        try expectEqual(history.records[.claude]?.familyBaselines?.ipv6, x)
        try expectEqual(history.unreadServices, [])
        observe(a)
        observe(x)
        observe(nil)
        observe(x)
        try expectEqual(history.records[.claude]?.changes.count, 3)
        try expectEqual(history.records[.claude]?.changes.first?.claudeDescription, "切换至 IPv6")
        try expectEqual(history.unreadServices, [])
        observe(b)
        let change = history.records[.claude]?.changes.first
        try expectEqual(change?.previous, x)
        try expectEqual(change?.previousInFamily, a)
        try expectEqual(change?.claudeDescription, "IPv4 出口变更")
        observe(x)
        try expectEqual(history.unreadServices, [.claude])
        history.markAllRead()
        observe(b)
        try expectEqual(history.unreadServices, [])
        observe(y)
        try expectEqual(history.records[.claude]?.changes.first?.previousInFamily, x)
        try expectEqual(history.unreadServices, [.claude])
        for i in 1...55 { observe("192.0.2.\(i)") }
        history.markAllRead()
        history.save(to: defaults)
        history = ExitIPHistory.load(from: defaults)
        observe(y)
        try expectEqual(history.unreadServices, [])
        observe(x)
        try expectEqual(history.unreadServices, [.claude])
        try expectEqual(history.records[.claude]?.changes.first?.previousInFamily, y)
    }

    private static func testAgentProbes() throws {
        let codex = AgentEndpoint.endpoints(for: .chatgpt)
        let claude = AgentEndpoint.endpoints(for: .claude)
        let google = AgentEndpoint.endpoints(for: .google)
        let service = codex.first { $0.url.path == "/backend-api/codex/responses" }!
        let token = claude.first { $0.contract == .oauthToken }!
        let login = claude.first { $0.contract == .claudeSignIn }!
        let host = google.first { $0.url.host == "aicode.googleapis.com" }!
        let cdn = codex.first { !$0.required }!
        func check(_ endpoint: AgentEndpoint, _ status: Int, _ body: String = "", redirect: String? = nil,
                   challenged: Bool = false) -> AgentProbeResult {
            .classify(endpoint, status: status, host: endpoint.url.host, data: Data(body.utf8),
                      location: redirect.flatMap { URL(string: $0) }, challenged: challenged)
        }
        try expect(codex.contains { $0.url.path == "/v1/responses" && $0.required })
        try expect(claude.contains { $0.url.path == "/v1/messages" && $0.required })
        try expect(google.contains { $0.url.host == "daily-cloudcode-pa.googleapis.com" && $0.required })
        for targets in [codex, claude, google] {
            try expectEqual(Set(targets.map(\.url)).count, targets.count)
            try expect(targets.allSatisfy { $0.url.scheme == "https" })
        }
        let ok = check(service, 401, #"{"detail":"Unauthorized"}"#)
        try expectEqual(ok.state, .green)
        try expectEqual(check(service, 401, "<html>Proxy login</html>").state, .unknown)
        try expectEqual(check(service, 404).state, .unknown)
        try expectEqual(check(service, 200, #"{"detail":"Unauthorized"}"#).state, .unknown)
        try expectEqual(check(service, 403, #"{"error":{"code":"unsupported_country_region_territory"}}"#).state, .yellow)
        try expectEqual(check(token, 400, #"{"error":{"type":"invalid_request_error"}}"#).state, .green)
        try expectEqual(check(token, 400, #"{"error":"unrelated_error"}"#).state, .unknown)
        try expectEqual(check(login, 307, redirect: "https://claude.ai/oauth/authorize").state, .green)
        try expectEqual(check(login, 307, redirect: "https://other.example/oauth/authorize").state, .unknown)
        try expectEqual(check(host, 404).state, .green)
        try expectEqual(check(host, 426).state, .green)
        let release = claude.first { $0.contract == .releaseFile }!
        try expectEqual(check(release, 404).state, .unknown)
        try expectEqual(check(release, 200).state, .green)
        try expectEqual(check(host, 403, challenged: true).state, .red)
        try expectEqual(check(host, 502).state, .red)
        let base = ServiceReport(kind: .chatgpt, state: .green, detail: "US", exitIP: "192.0.2.7")
        let auxiliaryFailure = check(cdn, 503)
        let report = base.including([ok, auxiliaryFailure])
        try expectEqual(report.state, .green)
        try expectEqual(report.endpoints.last, auxiliaryFailure)
        let failed = base.including([check(service, 502)])
        try expectEqual(failed.state, .red)
        try expectEqual(failed.exitIP, base.exitIP)
        try expect(failed.detail.contains(service.purpose))
        try expectEqual(base.including([check(service, 401, "bad")]).state, .unknown)
        let restricted = ServiceReport(kind: .claude, state: .yellow, detail: "JP")
        try expectEqual(restricted.including([ok]).state, .yellow)
    }

    // MARK: - Helpers

    private static func expect(_ condition: @autoclosure () -> Bool, file: StaticString = #file, line: UInt = #line) throws {
        testCount += 1
        guard condition() else {
            throw TestFailure(message: "Assertion failed at \(file):\(line)")
        }
    }

    private static func expectEqual<T: Equatable>(
        _ actual: @autoclosure () -> T,
        _ expected: T,
        file: StaticString = #file,
        line: UInt = #line
    ) throws {
        testCount += 1
        let actualValue = actual()
        guard actualValue == expected else {
            throw TestFailure(
                message: "Expected \(expected), got \(actualValue) at \(file):\(line)"
            )
        }
    }
}
