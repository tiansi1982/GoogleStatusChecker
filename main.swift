import Cocoa

private func statusColor(for state: CheckState) -> NSColor {
    switch state {
    case .green: return .systemGreen
    case .yellow: return .systemYellow
    case .red: return .systemRed
    case .unknown: return .systemBlue
    case .checking: return .systemGray
    }
}

/// Three independent, Apple-style status bars ordered Google / ChatGPT / Claude.
/// The 14.5 pt group is nearly square and stays legible in the macOS menu bar.
private func createServiceStatusImage(states: [CheckState]) -> NSImage {
    let size = NSSize(width: 18, height: 18)
    let image = NSImage(size: size, flipped: false) { rect in
        let normalizedStates = (0..<3).map { index in
            index < states.count ? states[index] : .checking
        }
        let barWidth: CGFloat = 4
        let gap: CGFloat = 1.25
        let groupWidth = barWidth * 3 + gap * 2
        let barHeight: CGFloat = 14.5
        let originX = rect.midX - groupWidth / 2
        let originY = rect.midY - barHeight / 2

        for (index, state) in normalizedStates.enumerated() {
            let barRect = NSRect(
                x: originX + CGFloat(index) * (barWidth + gap),
                y: originY,
                width: barWidth,
                height: barHeight
            )
            let path = NSBezierPath(roundedRect: barRect, xRadius: 2, yRadius: 2)
            let color = statusColor(for: state)
            let topColor = color.blended(withFraction: 0.18, of: .white) ?? color
            let bottomColor = color.blended(withFraction: 0.10, of: .black) ?? color

            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
            shadow.shadowBlurRadius = 1
            shadow.shadowOffset = NSSize(width: 0, height: -0.5)
            shadow.set()
            if let gradient = NSGradient(starting: bottomColor, ending: topColor) {
                gradient.draw(in: path, angle: 90)
            } else {
                color.setFill()
                path.fill()
            }
            NSGraphicsContext.restoreGraphicsState()

            NSColor.labelColor.withAlphaComponent(0.18).setStroke()
            path.lineWidth = 0.65
            path.stroke()

            let highlightRect = NSRect(
                x: barRect.minX + 0.65,
                y: barRect.minY + 1.5,
                width: 0.65,
                height: barRect.height - 3
            )
            NSColor.white.withAlphaComponent(0.24).setFill()
            NSBezierPath(roundedRect: highlightRect, xRadius: 0.32, yRadius: 0.32).fill()
        }
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
            "User-Agent": "GoogleStatusChecker/1.2",
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

private final class MultiServiceChecker: @unchecked Sendable {
    private let client = ProbeClient()

    private let googleProbeURL = URL(string: "https://www.google.com/generate_204")!
    private let googleRegionURL = URL(string: "https://www.cloudflare.com/cdn-cgi/trace")!

    private struct AIProbeSpec: Sendable {
        let kind: ServiceKind
        let edgeURL: URL
        let edgeDomain: String
        let apiURL: URL
        let apiProbe: APIProbe
    }

    private let aiSpecs: [ServiceKind: AIProbeSpec] = [
        .chatgpt: AIProbeSpec(
            kind: .chatgpt,
            edgeURL: URL(string: "https://chatgpt.com/cdn-cgi/trace")!,
            edgeDomain: "chatgpt.com",
            apiURL: URL(string: "https://api.openai.com/v1/models")!,
            apiProbe: .openAI
        ),
        .claude: AIProbeSpec(
            kind: .claude,
            edgeURL: URL(string: "https://claude.ai/cdn-cgi/trace")!,
            edgeDomain: "claude.ai",
            apiURL: URL(string: "https://api.anthropic.com/v1/models")!,
            apiProbe: .anthropic
        )
    ]

    func check(
        _ kind: ServiceKind,
        completion: @escaping @MainActor @Sendable (ServiceReport) -> Void
    ) {
        switch kind {
        case .google:
            checkGoogle(completion: completion)
        case .chatgpt, .claude:
            guard let spec = aiSpecs[kind] else { return }
            checkAI(spec: spec, completion: completion)
        }
    }

    private func checkGoogle(
        completion: @escaping @MainActor @Sendable (ServiceReport) -> Void
    ) {
        client.get(googleProbeURL) { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .failure(let error):
                self.finish(
                    ServiceReport(
                        kind: .google,
                        state: .red,
                        detail: "Google 连接失败：\(error.localizedDescription)"
                    ),
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
                        ServiceReport(
                            kind: .google,
                            state: .red,
                            detail: "Google 检测失败：\(detail)"
                        ),
                        completion: completion
                    )
                    return
                }
                self.checkExitRegion(completion: completion)
            }
        }
    }

    private func checkExitRegion(
        completion: @escaping @MainActor @Sendable (ServiceReport) -> Void
    ) {
        client.get(googleRegionURL) { [weak self] result in
            guard let self = self else { return }

            let report: ServiceReport
            switch result {
            case .failure(let error):
                report = ServiceReport(
                    kind: .google,
                    state: .unknown,
                    detail: "Google 可访问；Cloudflare 辅助探测失败：\(error.localizedDescription)"
                )
            case .success(let response):
                guard (200..<300).contains(response.statusCode),
                      let host = response.finalHost,
                      HostValidation.host(host, belongsTo: "cloudflare.com"),
                      let countryCode = ProbeClassifier.countryCode(fromCloudflareTrace: response.data) else {
                    report = ServiceReport(
                        kind: .google,
                        state: .unknown,
                        detail: "Google 可访问；Cloudflare 辅助探测无法确认出口地区"
                    )
                    self.finish(report, completion: completion)
                    return
                }
                report = ProbeClassifier.googleReport(forCountryCode: countryCode)
            }
            self.finish(report, completion: completion)
        }
    }

    private func checkAI(
        spec: AIProbeSpec,
        completion: @escaping @MainActor @Sendable (ServiceReport) -> Void
    ) {
        client.get(spec.edgeURL) { [weak self] result in
            guard let self = self else { return }

            let edge: CloudflareEdgeOutcome
            switch result {
            case .failure(let error):
                self.finish(
                    ServiceReport(
                        kind: spec.kind,
                        state: .red,
                        detail: "\(spec.kind.displayName) 连接失败：\(error.localizedDescription)"
                    ),
                    completion: completion
                )
                return
            case .success(let response):
                edge = ProbeClassifier.classifyEdge(
                    statusCode: response.statusCode,
                    finalHost: response.finalHost,
                    data: response.data,
                    zoneDomain: spec.edgeDomain
                )
            }

            switch edge {
            case .blocked:
                self.finish(ProbeClassifier.edgeBlockedReport(kind: spec.kind), completion: completion)
            case .unexpected(let reason):
                self.finish(
                    ProbeClassifier.edgeUnexpectedReport(kind: spec.kind, reason: reason),
                    completion: completion
                )
            case .reachable(let countryCode):
                self.checkAIAPI(spec: spec, edgeCountry: countryCode, completion: completion)
            }
        }
    }

    private func checkAIAPI(
        spec: AIProbeSpec,
        edgeCountry: String?,
        completion: @escaping @MainActor @Sendable (ServiceReport) -> Void
    ) {
        client.get(spec.apiURL) { [weak self] result in
            guard let self = self else { return }

            let api: APIRegionOutcome
            switch result {
            case .failure(let error):
                api = .connectionFailed(error.localizedDescription)
            case .success(let response):
                api = ProbeClassifier.classifyAPI(
                    statusCode: response.statusCode,
                    finalHost: response.finalHost,
                    data: response.data,
                    probe: spec.apiProbe
                )
            }
            self.finish(
                ProbeClassifier.aiReport(kind: spec.kind, edgeCountry: edgeCountry, api: api),
                completion: completion
            )
        }
    }

    private func finish(
        _ report: ServiceReport,
        completion: @escaping @MainActor @Sendable (ServiceReport) -> Void
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
        static let serviceBase = 200
        static let serviceDetailBase = 210
        static let lastCheck = 300
        static let checkNow = 301
    }

    private static let checkInterval: TimeInterval = 300
    private static let serviceOrder: [ServiceKind] = [.google, .chatgpt, .claude]

    private let statusItem: NSStatusItem
    private let checker = MultiServiceChecker()
    private let timeFormatter: DateFormatter
    private var timer: DispatchSourceTimer?
    private var reports: [ServiceKind: ServiceReport] = [:]
    private var lastCheckDate: Date?
    private var pendingChecks = 0

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"

        buildMenu()
        updateUI()
        performCheck()
        startTimer()
    }

    deinit {
        timer?.cancel()
    }

    private var aggregateState: CheckState {
        let allReports = Self.serviceOrder.compactMap { reports[$0] }
        return OverallStatus.state(of: allReports, isChecking: pendingChecks > 0)
    }

    private var orderedServiceStates: [CheckState] {
        Self.serviceOrder.map { reports[$0]?.state ?? .checking }
    }

    private var accessibilityValue: String {
        Self.serviceOrder.map { kind in
            let state = reports[kind]?.state ?? .checking
            return "\(kind.displayName) \(state.summary)"
        }.joined(separator: "，")
    }

    private var aggregateLabel: String {
        switch aggregateState {
        case .green:
            return "绿灯 - Google / ChatGPT / Claude 的检测信号均为美国出口"
        case .yellow:
            return "黄灯 - 至少一项未确认使用美国出口，详见下方"
        case .checking:
            return "检测中..."
        case .red, .unknown:
            return "检测中..."
        }
    }

    private var tooltipText: String {
        var lines = [aggregateLabel]
        for kind in Self.serviceOrder {
            let report = reports[kind] ?? .checking(kind)
            lines.append(report.title)
            lines.append("　" + report.detail)
        }
        return lines.joined(separator: "\n")
    }

    private func buildMenu() {
        let menu = NSMenu()

        let statusRow = NSMenuItem(title: "状态：检测中...", action: nil, keyEquivalent: "")
        statusRow.isEnabled = false
        statusRow.tag = MenuTag.status
        menu.addItem(statusRow)

        for (index, kind) in Self.serviceOrder.enumerated() {
            let titleRow = NSMenuItem(title: "\(kind.displayName)：检测中", action: nil, keyEquivalent: "")
            titleRow.isEnabled = false
            titleRow.tag = MenuTag.serviceBase + index
            menu.addItem(titleRow)

            let detailRow = NSMenuItem(title: "　检测中", action: nil, keyEquivalent: "")
            detailRow.isEnabled = false
            detailRow.tag = MenuTag.serviceDetailBase + index
            menu.addItem(detailRow)
        }

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

        menu.addItem(.separator())

        let links: [(title: String, key: String, url: String)] = [
            ("在浏览器中打开 Google", "o", "https://www.google.com/"),
            ("在浏览器中打开 ChatGPT", "g", "https://chatgpt.com/"),
            ("在浏览器中打开 Claude", "l", "https://claude.ai/")
        ]
        for link in links {
            let item = NSMenuItem(
                title: link.title,
                action: #selector(openLinkClicked(_:)),
                keyEquivalent: link.key
            )
            item.target = self
            item.representedObject = link.url
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "退出 GoogleStatusChecker",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        refreshMenuTitles()
    }

    private func refreshMenuTitles() {
        guard let menu = statusItem.menu else { return }

        menu.item(withTag: MenuTag.status)?.title = "状态：\(aggregateLabel)"

        for (index, kind) in Self.serviceOrder.enumerated() {
            let report = reports[kind] ?? .checking(kind)
            menu.item(withTag: MenuTag.serviceBase + index)?.title = report.title
            menu.item(withTag: MenuTag.serviceDetailBase + index)?.title = "　" + report.detail
        }

        menu.item(withTag: MenuTag.checkNow)?.isEnabled = pendingChecks == 0

        if let lastCheckDate = lastCheckDate {
            menu.item(withTag: MenuTag.lastCheck)?.title = "上次检测：\(timeFormatter.string(from: lastCheckDate))"
        } else {
            menu.item(withTag: MenuTag.lastCheck)?.title = "上次检测：—"
        }
    }

    @objc private func checkNowClicked() {
        performCheck()
    }

    @objc private func openLinkClicked(_ sender: NSMenuItem) {
        guard let urlString = sender.representedObject as? String,
              let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
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
        guard pendingChecks == 0 else { return }
        pendingChecks = Self.serviceOrder.count
        for kind in Self.serviceOrder {
            reports[kind] = .checking(kind)
        }
        updateUI()

        for kind in Self.serviceOrder {
            checker.check(kind) { [weak self] report in
                guard let self = self else { return }
                self.reports[report.kind] = report
                self.pendingChecks -= 1
                if self.pendingChecks == 0 {
                    self.lastCheckDate = Date()
                }
                self.updateUI()
            }
        }
    }

    private func updateUI() {
        if let button = statusItem.button {
            button.image = createServiceStatusImage(states: orderedServiceStates)
            button.imageScaling = .scaleNone
            let text = tooltipText
            button.toolTip = text
            button.setAccessibilityLabel("Google、ChatGPT、Claude 出口状态")
            button.setAccessibilityValue(accessibilityValue)
            button.setAccessibilityHelp(text)
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
