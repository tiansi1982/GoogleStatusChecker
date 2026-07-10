import Foundation

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
        try testReportClassification()
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
            ProbeClassifier.countryCode(fromCloudflareTrace: Data(repeating: 65, count: 64 * 1024 + 1)),
            nil
        )
    }

    private static func testReportClassification() throws {
        try expectEqual(ProbeClassifier.report(forCountryCode: "us").state, .green)
        try expectEqual(ProbeClassifier.report(forCountryCode: "JP").state, .yellow)
        try expectEqual(ProbeClassifier.report(forCountryCode: "XX").state, .unknown)
    }

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
