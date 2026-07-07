//
//  GoogleStatusChecker - macOS 状态栏小程序
//  检测当前网络环境对 Google 美国网站的访问情况：
//    绿灯 = 可正常访问 Google 美国
//    黄灯 = 可访问 Google，但被重定向到其他国家版本
//    红灯 = 无法访问 Google
//

import Cocoa

// MARK: - 检测结果

enum CheckResult {
    case green    // 可访问 Google 美国
    case yellow   // 可访问 Google，但不是美国版本
    case red      // 无法访问 Google
    case checking // 检测中

    var label: String {
        switch self {
        case .green:    return "绿灯 - Google 美国可正常访问"
        case .yellow:   return "黄灯 - 可访问 Google，但不是美国版本"
        case .red:      return "红灯 - 无法访问 Google"
        case .checking: return "检测中..."
        }
    }
}

// MARK: - 图标绘制

/// 绘制状态栏圆形指示灯图标
func createCircleImage(color: NSColor) -> NSImage {
    let size = NSSize(width: 18, height: 18)
    let image = NSImage(size: size, flipped: false) { rect in
        // 外圈描边（暗色主题下增强可见性）
        NSColor.labelColor.withAlphaComponent(0.35).setStroke()
        let strokeRect = rect.insetBy(dx: 3, dy: 3)
        let outerPath = NSBezierPath(ovalIn: strokeRect)
        outerPath.lineWidth = 1
        outerPath.stroke()

        // 内部填充圆形
        color.setFill()
        let fillRect = strokeRect.insetBy(dx: 1, dy: 1)
        NSBezierPath(ovalIn: fillRect).fill()

        // 高光效果（让灯看起来更立体）
        let highlight = NSColor.white.withAlphaComponent(0.35)
        highlight.setFill()
        let highlightRect = NSRect(x: fillRect.minX + 1.5,
                                   y: fillRect.midY,
                                   width: fillRect.width - 3,
                                   height: fillRect.height / 2.5)
        NSBezierPath(ovalIn: highlightRect).fill()
        return true
    }
    image.isTemplate = false
    return image
}

// MARK: - Google 检测器

class GoogleChecker {
    /// 异步执行检测，完成后在主线程回调
    func check(completion: @escaping (CheckResult) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = self.performCheck()
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    /// 同步执行一次完整检测
    private func performCheck() -> CheckResult {
        // 访问 google.com，跟随重定向，检查最终 URL 与页面内容
        guard let url = URL(string: "https://www.google.com/") else {
            return .red
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        // 使用桌面浏览器 User-Agent，避免被重定向到移动版
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
            + "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        // 禁用缓存，保证每次都是真实检测
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let semaphore = DispatchSemaphore(value: 0)
        var finalURL: URL? = nil
        var requestError: Error? = nil
        var responseData: Data? = nil
        var httpStatus: Int = 0

        let session = URLSession(configuration: config)
        let task = session.dataTask(with: request) { data, response, err in
            if let err = err {
                requestError = err
            } else if let http = response as? HTTPURLResponse {
                httpStatus = http.statusCode
                finalURL = http.url
                responseData = data
            }
            semaphore.signal()
        }
        task.resume()

        let waitResult = semaphore.wait(timeout: .now() + 15)
        session.finishTasksAndInvalidate()

        // 超时视为无法访问
        if waitResult == .timedOut {
            return .red
        }
        if requestError != nil {
            return .red
        }
        // 非 2xx 状态码视为不可访问
        if !(200..<400).contains(httpStatus) {
            return .red
        }

        guard let finalURL = finalURL else {
            return .red
        }

        let host = (finalURL.host ?? "").lowercased()

        // 不是 google 域名 → 视为不可访问
        if !host.contains("google") {
            return .red
        }

        // 最终落在 www.google.com / google.com → 需进一步检查内容是否被 JS 重定向
        if host == "www.google.com" || host == "google.com" {
            if let data = responseData, let html = String(data: data, encoding: .utf8) {
                if let redirectHost = countryRedirectTarget(in: html) {
                    // 页面内有 JS 重定向到其他 Google 域名
                    print("检测到 JS 重定向到: \(redirectHost)")
                    return .yellow
                }
                // 检查页面中显式标注的国家/地区
                if let detectedCountry = detectCountry(in: html) {
                    print("页面检测到国家代码: \(detectedCountry)")
                    // US 视为美国，其他视为黄灯
                    if detectedCountry.uppercased() == "US" {
                        return .green
                    } else {
                        return .yellow
                    }
                }
            }
            // 没有重定向，也没有明显的国家标识 → 默认美国
            return .green
        }

        // 最终 URL 是其他 google.* 域名（如 google.co.jp / google.com.hk）→ 黄灯
        return .yellow
    }

    /// 从 HTML 中提取 Google 的国家重定向目标域名
    /// Google 国家重定向常见形式:
    ///   window.location.replace("https://www.google.com.sg/")
    ///   <meta http-equiv="refresh" content="0;url=https://www.google.co.jp/">
    private func countryRedirectTarget(in html: String) -> String? {
        // 1) location.replace("https://www.google.xxx/")
        let replacePattern = #"location\.replace\(\s*["'](https?://[^"']+)["']\s*\)"#
        if let match = firstRegexMatch(in: html, pattern: replacePattern),
           let u = URL(string: match), let h = u.host?.lowercased(),
           h.contains("google"), h != "www.google.com", h != "google.com" {
            return h
        }

        // 2) location.href = "https://www.google.xxx/"
        let hrefPattern = #"location\.href\s*=\s*["'](https?://[^"']+)["']"#
        if let match = firstRegexMatch(in: html, pattern: hrefPattern),
           let u = URL(string: match), let h = u.host?.lowercased(),
           h.contains("google"), h != "www.google.com", h != "google.com" {
            return h
        }

        // 3) meta refresh
        let metaPattern = #"<meta[^>]+url=(https?://[^"'\s>]+)"#
        if let match = firstRegexMatch(in: html, pattern: metaPattern),
           let u = URL(string: match), let h = u.host?.lowercased(),
           h.contains("google"), h != "www.google.com", h != "google.com" {
            return h
        }

        return nil
    }

    /// 检测 HTML 中显式标注的国家代码（例如 Google 页面里的 kHL / gl 参数）
    private func detectCountry(in html: String) -> String? {
        // google.kHL="zh-CN" / "en-US"  → 取最后一段作为国家
        let khlPattern = #"kHL\s*[:=]\s*["']([a-zA-Z]{2})-([a-zA-Z]{2})["']"#
        if let m = firstRegexGroup(in: html, pattern: khlPattern, group: 2) {
            return m.uppercased()
        }
        // window.location 之外的 gl=XX
        let glPattern = #"["'?&]gl=([a-zA-Z]{2})"#
        if let m = firstRegexGroup(in: html, pattern: glPattern, group: 1) {
            return m.uppercased()
        }
        return nil
    }

    private func firstRegexMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[r])
    }

    private func firstRegexGroup(in text: String, pattern: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > group,
              let r = Range(match.range(at: group), in: text) else {
            return nil
        }
        return String(text[r])
    }
}

// MARK: - 状态栏控制器

class StatusBarController {
    private let statusItem: NSStatusItem
    private let greenImage: NSImage
    private let yellowImage: NSImage
    private let redImage: NSImage
    private let grayImage: NSImage

    private let checker = GoogleChecker()
    private var timer: DispatchSourceTimer?
    private var lastResult: CheckResult = .checking
    private var lastCheckDate: Date?
    private var isChecking = false

    private static let checkInterval: TimeInterval = 300 // 5 分钟自动检测一次

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        greenImage = createCircleImage(color: NSColor.systemGreen)
        yellowImage = createCircleImage(color: NSColor.systemYellow)
        redImage = createCircleImage(color: NSColor.systemRed)
        grayImage = createCircleImage(color: NSColor.systemGray)

        updateStatus(.checking)
        buildMenu()
        performCheck()
        startTimer()
    }

    // MARK: 菜单

    private func buildMenu() {
        let menu = NSMenu()

        let statusMenuItem = NSMenuItem(title: "状态：检测中...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        statusMenuItem.tag = 100
        menu.addItem(statusMenuItem)

        let lastItem = NSMenuItem(title: "上次检测：—", action: nil, keyEquivalent: "")
        lastItem.isEnabled = false
        lastItem.tag = 101
        menu.addItem(lastItem)

        menu.addItem(NSMenuItem.separator())

        let checkNow = NSMenuItem(title: "立即重新检测",
                                  action: #selector(checkNowClicked),
                                  keyEquivalent: "r")
        checkNow.target = self
        menu.addItem(checkNow)

        let openItem = NSMenuItem(title: "在浏览器中打开 Google",
                                  action: #selector(openGoogleClicked),
                                  keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出 GoogleStatusChecker",
                                  action: #selector(quitClicked),
                                  keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        self.statusItem.menu = menu
        refreshMenuTitles()
    }

    private func refreshMenuTitles() {
        if let menu = statusItem.menu {
            if let item = menu.item(withTag: 100) {
                item.title = "状态：\(lastResult.label)"
            }
            if let item = menu.item(withTag: 101) {
                if let date = lastCheckDate {
                    let fmt = DateFormatter()
                    fmt.dateFormat = "HH:mm:ss"
                    item.title = "上次检测：\(fmt.string(from: date))"
                } else {
                    item.title = "上次检测：—"
                }
            }
        }
    }

    @objc private func checkNowClicked() {
        performCheck()
    }

    @objc private func openGoogleClicked() {
        if let url = URL(string: "https://www.google.com/") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quitClicked() {
        NSApplication.shared.terminate(self)
    }

    // MARK: 定时器

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + Self.checkInterval, repeating: Self.checkInterval)
        t.setEventHandler { [weak self] in
            self?.performCheck()
        }
        t.resume()
        timer = t
    }

    // MARK: 检测

    private func performCheck() {
        guard !isChecking else { return }
        isChecking = true
        updateStatus(.checking)
        checker.check { [weak self] result in
            guard let self = self else { return }
            self.isChecking = false
            self.lastCheckDate = Date()
            self.updateStatus(result)
        }
    }

    private func updateStatus(_ result: CheckResult) {
        lastResult = result
        let image: NSImage
        switch result {
        case .green:    image = greenImage
        case .yellow:   image = yellowImage
        case .red:      image = redImage
        case .checking: image = grayImage
        }
        if let button = statusItem.button {
            button.image = image
            button.toolTip = result.label
        }
        refreshMenuTitles()
    }
}

// MARK: - 应用代理

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 隐藏 Dock 图标（保险，主要靠 Info.plist 的 LSUIElement）
        NSApp.setActivationPolicy(.accessory)
        statusBarController = StatusBarController()
    }
}

// MARK: - 入口

let appDelegate = AppDelegate()
NSApplication.shared.delegate = appDelegate
NSApplication.shared.run()
