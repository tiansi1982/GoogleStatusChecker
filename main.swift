import Cocoa

private func createCircleImage(color: NSColor) -> NSImage {
    let size = NSSize(width: 18, height: 18)
    let image = NSImage(size: size, flipped: false) { rect in
        NSColor.labelColor.withAlphaComponent(0.35).setStroke()
        let strokeRect = rect.insetBy(dx: 3, dy: 3)
        let outerPath = NSBezierPath(ovalIn: strokeRect)
        outerPath.lineWidth = 1
        outerPath.stroke()

        color.setFill()
        let fillRect = strokeRect.insetBy(dx: 1, dy: 1)
        NSBezierPath(ovalIn: fillRect).fill()

        NSColor.white.withAlphaComponent(0.35).setFill()
        let highlightRect = NSRect(
            x: fillRect.minX + 1.5,
            y: fillRect.midY,
            width: fillRect.width - 3,
            height: fillRect.height / 2.5
        )
        NSBezierPath(ovalIn: highlightRect).fill()
        return true
    }
    image.isTemplate = false
    return image
}

private enum ProbeError: LocalizedError {
    case invalidResponse
    case unexpectedStatus(Int)
    case unexpectedHost(String)
    case invalidCountryResponse

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "服务器返回了无效响应"
        case .unexpectedStatus(let status):
            return "HTTP 状态码 \(status)"
        case .unexpectedHost(let host):
            return "请求落到了非预期域名 \(host)"
        case .invalidCountryResponse:
            return "地区服务未返回有效国家代码"
        }
    }
}

private struct HTTPProbeResponse: Sendable {
    let data: Data
    let statusCode: Int
    let finalHost: String?
}

private final class ProbeClient: @unchecked Sendable {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 12
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpAdditionalHeaders = [
            "User-Agent": "GoogleStatusChecker/1.1",
            "Accept": "text/plain"
        ]
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func get(
        _ url: URL,
        completion: @escaping @Sendable (Result<HTTPProbeResponse, Error>) -> Void
    ) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let response = response as? HTTPURLResponse else {
                completion(.failure(ProbeError.invalidResponse))
                return
            }
            completion(.success(HTTPProbeResponse(
                data: data ?? Data(),
                statusCode: response.statusCode,
                finalHost: response.url?.host?.lowercased()
            )))
        }.resume()
    }
}

private final class GoogleChecker: @unchecked Sendable {
    private let client = ProbeClient()
    private let googleProbeURL = URL(string: "https://www.google.com/generate_204")!
    private let regionProbeURL = URL(string: "https://www.cloudflare.com/cdn-cgi/trace")!

    func check(completion: @escaping @MainActor @Sendable (CheckReport) -> Void) {
        client.get(googleProbeURL) { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .failure(let error):
                self.finish(
                    CheckReport(state: .red, detail: "Google 连接失败：\(error.localizedDescription)"),
                    completion: completion
                )
            case .success(let response):
                guard ProbeClassifier.googleIsReachable(
                    statusCode: response.statusCode,
                    finalHost: response.finalHost
                ) else {
                    let detail: String
                    if response.statusCode != 204 {
                        detail = ProbeError.unexpectedStatus(response.statusCode).localizedDescription
                    } else {
                        detail = ProbeError.unexpectedHost(response.finalHost ?? "未知").localizedDescription
                    }
                    self.finish(
                        CheckReport(state: .red, detail: "Google 检测失败：\(detail)"),
                        completion: completion
                    )
                    return
                }
                self.checkExitRegion(completion: completion)
            }
        }
    }

    private func checkExitRegion(
        completion: @escaping @MainActor @Sendable (CheckReport) -> Void
    ) {
        client.get(regionProbeURL) { [weak self] result in
            guard let self = self else { return }

            let report: CheckReport
            switch result {
            case .failure(let error):
                report = CheckReport(
                    state: .unknown,
                    detail: "Google 可访问；出口地区估算失败：\(error.localizedDescription)"
                )
            case .success(let response):
                guard (200..<300).contains(response.statusCode),
                      let host = response.finalHost,
                      HostValidation.host(host, belongsTo: "cloudflare.com"),
                      let countryCode = ProbeClassifier.countryCode(fromCloudflareTrace: response.data) else {
                    report = CheckReport(
                        state: .unknown,
                        detail: "Google 可访问；出口地区估算失败：\(ProbeError.invalidCountryResponse.localizedDescription)"
                    )
                    self.finish(report, completion: completion)
                    return
                }
                report = ProbeClassifier.report(forCountryCode: countryCode)
            }
            self.finish(report, completion: completion)
        }
    }

    private func finish(
        _ report: CheckReport,
        completion: @escaping @MainActor @Sendable (CheckReport) -> Void
    ) {
        DispatchQueue.main.async {
            completion(report)
        }
    }
}

@MainActor
private final class StatusBarController {
    private enum MenuTag {
        static let status = 100
        static let lastCheck = 101
        static let detail = 102
        static let checkNow = 103
    }

    private static let checkInterval: TimeInterval = 300

    private let statusItem: NSStatusItem
    private let checker = GoogleChecker()
    private let images: [CheckState: NSImage]
    private let timeFormatter: DateFormatter
    private var timer: DispatchSourceTimer?
    private var lastReport = CheckReport.checking
    private var lastCheckDate: Date?
    private var isChecking = false

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        images = [
            .green: createCircleImage(color: .systemGreen),
            .yellow: createCircleImage(color: .systemYellow),
            .red: createCircleImage(color: .systemRed),
            .unknown: createCircleImage(color: .systemBlue),
            .checking: createCircleImage(color: .systemGray)
        ]

        timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"

        buildMenu()
        updateStatus(.checking)
        performCheck()
        startTimer()
    }

    deinit {
        timer?.cancel()
    }

    private func buildMenu() {
        let menu = NSMenu()

        let statusItem = NSMenuItem(title: "状态：检测中...", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        statusItem.tag = MenuTag.status
        menu.addItem(statusItem)

        let detailItem = NSMenuItem(title: "正在检测 Google 连通性", action: nil, keyEquivalent: "")
        detailItem.isEnabled = false
        detailItem.tag = MenuTag.detail
        menu.addItem(detailItem)

        let lastItem = NSMenuItem(title: "上次检测：—", action: nil, keyEquivalent: "")
        lastItem.isEnabled = false
        lastItem.tag = MenuTag.lastCheck
        menu.addItem(lastItem)

        menu.addItem(.separator())

        let checkNow = NSMenuItem(
            title: "立即重新检测",
            action: #selector(checkNowClicked),
            keyEquivalent: "r"
        )
        checkNow.target = self
        checkNow.tag = MenuTag.checkNow
        menu.addItem(checkNow)

        let openItem = NSMenuItem(
            title: "在浏览器中打开 Google",
            action: #selector(openGoogleClicked),
            keyEquivalent: "o"
        )
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "退出 GoogleStatusChecker",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        self.statusItem.menu = menu
        refreshMenuTitles()
    }

    private func refreshMenuTitles() {
        guard let menu = statusItem.menu else { return }
        menu.item(withTag: MenuTag.status)?.title = "状态：\(lastReport.state.label)"
        menu.item(withTag: MenuTag.detail)?.title = lastReport.detail
        menu.item(withTag: MenuTag.checkNow)?.isEnabled = !isChecking

        if let lastCheckDate = lastCheckDate {
            menu.item(withTag: MenuTag.lastCheck)?.title = "上次检测：\(timeFormatter.string(from: lastCheckDate))"
        } else {
            menu.item(withTag: MenuTag.lastCheck)?.title = "上次检测：—"
        }
    }

    @objc private func checkNowClicked() {
        performCheck()
    }

    @objc private func openGoogleClicked() {
        NSWorkspace.shared.open(URL(string: "https://www.google.com/")!)
    }

    @objc private func quitClicked() {
        NSApplication.shared.terminate(self)
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + Self.checkInterval,
            repeating: Self.checkInterval,
            leeway: .seconds(15)
        )
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.performCheck()
            }
        }
        timer.resume()
        self.timer = timer
    }

    private func performCheck() {
        guard !isChecking else { return }
        isChecking = true
        updateStatus(.checking)

        checker.check { [weak self] report in
            guard let self = self else { return }
            self.isChecking = false
            self.lastCheckDate = Date()
            self.lastReport = report
            self.updateStatus(report.state)
        }
    }

    private func updateStatus(_ state: CheckState) {
        if state == .checking {
            lastReport = .checking
        }
        if let button = statusItem.button {
            button.image = images[state]
            button.toolTip = "\(lastReport.state.label)\n\(lastReport.detail)"
            button.setAccessibilityLabel(lastReport.state.label)
            button.setAccessibilityHelp(lastReport.detail)
        }
        refreshMenuTitles()
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusBarController = StatusBarController()
    }
}

private let appDelegate = AppDelegate()
NSApplication.shared.delegate = appDelegate
NSApplication.shared.run()
