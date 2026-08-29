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

        try expectEqual(ProbeClassifier.countryCode(fromCloudflareTrace: usTrace), "US")
        try expectEqual(ProbeClassifier.countryCode(fromCloudflareTrace: lowercaseTrace), "JP")
        try expectEqual(ProbeClassifier.countryCode(fromCloudflareTrace: malformedTrace), nil)
        try expectEqual(ProbeClassifier.countryCode(fromCloudflareTrace: missingTrace), nil)
        try expectEqual(ProbeClassifier.countryCode(fromCloudflareTrace: Data([0xFF])), nil)
        try expectEqual(
            ProbeClassifier.countryCode(fromCloudflareTrace: Data(repeating: 65, count: maxProbeBodyBytes + 1)),
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
            CloudflareEdgeOutcome.reachable(countryCode: "US")
        )
        try expectEqual(
            ProbeClassifier.classifyEdge(
                statusCode: 200, finalHost: "claude.ai", data: noLocTrace, zoneDomain: "claude.ai"
            ),
            CloudflareEdgeOutcome.reachable(countryCode: nil)
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
