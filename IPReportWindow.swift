import Cocoa

@MainActor
final class IPReportWindow: NSWindow {
    private let reportText = NSTextView()
    private let dateFormatter = DateFormatter()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 600, height: 480),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                   backing: .buffered, defer: false)
        title = "出口 IP 变化报告"
        minSize = NSSize(width: 410, height: 300)
        isReleasedWhenClosed = false
        center()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .medium

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        reportText.isEditable = false
        reportText.isSelectable = true
        reportText.isVerticallyResizable = true
        reportText.isHorizontallyResizable = false
        reportText.autoresizingMask = .width
        reportText.textContainer?.widthTracksTextView = true
        reportText.textContainerInset = NSSize(width: 20, height: 16)
        reportText.setAccessibilityLabel(title)
        contentView = scroll
        reportText.frame.size.width = scroll.contentSize.width
        scroll.documentView = reportText
    }

    func display(_ history: ExitIPHistory, scrollToTop: Bool = false) {
        let text = NSMutableAttributedString()
        let heading = NSFont.systemFont(ofSize: 17, weight: .semibold)
        let label = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let address = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let caption = NSFont.systemFont(ofSize: 12)
        func append(_ value: String, _ font: NSFont, _ color: NSColor = .labelColor) {
            text.append(NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: color]))
        }

        append("最近确认的出口 IP\n\n", heading)
        for kind in ServiceKind.allCases {
            append("\(kind.displayName)    ", label)
            if let record = history.records[kind] {
                if let baselines = record.familyBaselines, kind == .claude {
                    append("\n", label)
                    for (family, ip) in [("IPv4", baselines.ipv4), ("IPv6", baselines.ipv6)] {
                        append("\(family)    ", caption, .secondaryLabelColor)
                        append(ip ?? "尚未取得", address)
                        append(ip == record.address ? "    · 最近使用\n" : "\n", caption, .secondaryLabelColor)
                    }
                } else {
                    append(record.address + "\n", address)
                }
                append("上次确认 " + dateFormatter.string(from: record.lastSeen) + "   ·   ", caption, .secondaryLabelColor)
            } else {
                append("尚未取得 IP\n", caption, .secondaryLabelColor)
            }
            let source: String
            switch kind {
            case .google: source = "cloudflare.com 辅助探测，分流时可能与 Google 出口不同"
            case .chatgpt: source = "chatgpt.com 网页入口"
            case .claude: source = "claude.ai 网页入口"
            }
            append(source + "\n\n", caption, .secondaryLabelColor)
        }

        append("变化记录\n\n", heading)
        let changes = history.records.flatMap { kind, record in
            record.changes.map { (kind, $0) }
        }.sorted { $0.1.date > $1.1.date }
        if changes.isEmpty {
            append("暂无变化。首次取得的 IP 用作后续比较的基线。", caption, .secondaryLabelColor)
        }
        for (kind, change) in changes {
            let title = kind == .claude ? "Claude · " + change.claudeDescription : kind.displayName
            append(title + "    ", label)
            append(dateFormatter.string(from: change.date) + "\n", caption, .secondaryLabelColor)
            append("原 IP    ", caption, .secondaryLabelColor)
            let previous = change.changedWithinFamily ? change.previousInFamily : nil
            append((previous ?? change.previous) + "\n", address)
            append("新 IP    ", caption, .secondaryLabelColor)
            append(change.current + "\n\n", address)
        }
        reportText.textStorage?.setAttributedString(text)
        if scrollToTop { reportText.scrollToBeginningOfDocument(nil) }
    }
}
