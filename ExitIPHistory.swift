import Foundation

struct ExitIPChange: Codable, Equatable {
    let date: Date
    let previous: String
    let current: String
    var previousInFamily: String?

    var changedWithinFamily: Bool {
        guard let previousInFamily else { return false }
        return previousInFamily != current
    }

    var claudeDescription: String {
        let family = current.contains(":") ? "IPv6" : "IPv4"
        return changedWithinFamily ? "\(family) 出口变更" : "切换至 \(family)"
    }
}

struct IPFamilyBaselines: Codable, Equatable {
    private(set) var ipv4: String?
    private(set) var ipv6: String?

    // Probe addresses are already validated and normalized.
    mutating func remember(_ address: String) -> String? {
        if address.contains(":") {
            let previous = ipv6
            ipv6 = address
            return previous
        }
        let previous = ipv4
        ipv4 = address
        return previous
    }
}

struct ExitIPRecord: Codable, Equatable {
    var address: String
    var lastSeen: Date
    var changes: [ExitIPChange] = []
    var hasUnreadChange = false
    var familyBaselines: IPFamilyBaselines?

    mutating func restoreClaudeBaselines() {
        guard familyBaselines == nil else { return }
        var baselines = IPFamilyBaselines()
        // The oldest retained transition also contains the address that preceded it.
        for index in changes.indices.reversed() {
            _ = baselines.remember(changes[index].previous)
            changes[index].previousInFamily = baselines.remember(changes[index].current)
        }
        _ = baselines.remember(address)
        familyBaselines = baselines
        if !changes.contains(where: \.changedWithinFamily) { hasUnreadChange = false }
    }
}

struct ExitIPHistory: Codable, Equatable {
    static let changesPerService = 50
    private static let defaultsKey = "exitIPHistory.v1"
    private(set) var records: [ServiceKind: ExitIPRecord] = [:]

    var unreadServices: Set<ServiceKind> {
        Set(records.keys.filter { records[$0]?.hasUnreadChange == true })
    }

    mutating func observe(_ report: ServiceReport, at date: Date) {
        guard let address = report.exitIP else { return }
        var record = records[report.kind] ?? ExitIPRecord(address: address, lastSeen: date,
            familyBaselines: report.kind == .claude ? IPFamilyBaselines() : nil)
        let previousInFamily = record.familyBaselines?.remember(address)
        if record.address != address {
            let change = ExitIPChange(date: date, previous: record.address, current: address,
                                      previousInFamily: previousInFamily)
            record.changes.insert(change, at: 0)
            if record.changes.count > Self.changesPerService { record.changes.removeLast() }
            if report.kind != .claude || change.changedWithinFamily { record.hasUnreadChange = true }
            record.address = address
        }
        record.lastSeen = date
        records[report.kind] = record
    }

    mutating func markAllRead() {
        for kind in unreadServices { records[kind]?.hasUnreadChange = false }
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: defaultsKey),
              var history = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        history.records[.claude]?.restoreClaudeBaselines()
        return history
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
