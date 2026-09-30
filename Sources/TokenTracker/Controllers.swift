import Foundation

@MainActor
protocol UsageController: AnyObject {
    var profile: Profile { get }
    var session: ClaudeSession { get }
    var status: FetchStatus { get }
    var lastSuccess: Date? { get }
    var lastAttempt: Date { get }
    func refresh() async
    func signOut() async
}

/// How often each widget re-reads claude.ai. Refreshes are small API calls on an already
/// open page; the page itself is reloaded every few hours to keep the session fresh.
enum RefreshPolicy {
    static let interval: TimeInterval = 2 * 60
    /// After a failure, try again sooner (but not in a tight loop).
    static let retryInterval: TimeInterval = 60
}

@MainActor
final class EnterpriseController: UsageController {
    let profile = Profile.enterprise
    let session = ClaudeSession(profile: .enterprise)
    let model = EnterpriseModel()
    private(set) var lastAttempt = Date.distantPast
    private var busy = false
    private var organization: String?
    private static let spendURLKey = "learnedSpendURL.enterprise"

    var status: FetchStatus { model.status }
    var lastSuccess: Date? { model.usage?.fetchedAt }

    init() {
        model.usage = Storage.load(EnterpriseUsage.self, "enterprise-usage")
        rebuildDays()
    }

    func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        lastAttempt = Date()
        if model.usage == nil { model.status = .loading }
        do {
            try await session.ensureReady(waitingFor: "/usage/spend")
            let org = try await organizationID()
            let usageJSON = try await session.fetchJSON("/api/organizations/\(org)/usage")
            var spendJSON = try? await session.fetchJSON(spendPath(org: org))
            if spendJSON == nil, let body = session.captured(endingWith: "/usage/spend") {
                spendJSON = try? JSONSerialization.jsonObject(with: Data(body.utf8))
            }
            guard let usage = EnterpriseParser.parse(usage: usageJSON, spend: spendJSON) else {
                throw SessionError.unexpected("claude.ai returned spend in an unexpected format")
            }
            model.usage = usage
            model.status = .idle
            Storage.save(usage, "enterprise-usage")
            rebuildDays()
        } catch SessionError.signedOut {
            session.invalidate()
            organization = nil
            model.status = .signedOut
        } catch {
            session.invalidate()
            model.status = .error(error.localizedDescription)
        }
    }

    /// The organization the usage page itself reports on, from its own requests.
    private func organizationID() async throws -> String {
        if let organization { return organization }
        for path in session.captures.keys {
            let parts = path.split(separator: "/")
            if parts.count >= 4, parts[0] == "api", parts[1] == "organizations", parts[3] == "usage" {
                organization = String(parts[2])
                return String(parts[2])
            }
        }
        guard let orgs = try await session.fetchJSON("/api/organizations") as? [[String: Any]],
              let uuid = orgs.first?["uuid"] as? String else {
            throw SessionError.unexpected("No claude.ai organization found for this account")
        }
        organization = uuid
        return uuid
    }

    /// The usage page's own spend request, re-dated to the current month.
    private func spendPath(org: String) -> String {
        if let seen = session.capturedURL(endingWith: "/usage/spend") {
            UserDefaults.standard.set(seen, forKey: Self.spendURLKey)
        }
        let template = UserDefaults.standard.string(forKey: Self.spendURLKey)
            ?? "/api/organizations/\(org)/usage/spend?start_date=&end_date=&group_by=product_surface&granularity=daily"
        guard var components = URLComponents(string: template),
              let month = EnterpriseParser.currentMonthRange() else { return template }
        components.queryItems = components.queryItems?.map { item in
            switch item.name {
            case "start_date": return URLQueryItem(name: item.name, value: month.start)
            case "end_date": return URLQueryItem(name: item.name, value: month.end)
            default: return item
            }
        }
        return components.string ?? template
    }

    private func rebuildDays() {
        model.days = Self.utcDays(from: model.usage?.daily ?? [:])
    }

    /// The usage page reports days in UTC.
    private static func utcDays(from daily: [String: [String: Double]], now: Date = Date()) -> [DayBar] {
        let utc = EnterpriseParser.utcCalendar
        let formatter = DateFormatter()
        formatter.calendar = utc
        formatter.timeZone = utc.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = utc.startOfDay(for: now)
        return (0..<7).reversed().compactMap { offset in
            guard let day = utc.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return DayBar(date: day, segments: daily[formatter.string(from: day)] ?? [:], isToday: offset == 0)
        }
    }

    func signOut() async {
        await session.signOut()
        organization = nil
        model.usage = nil
        model.days = []
        model.status = .signedOut
        try? FileManager.default.removeItem(at: Storage.directory.appendingPathComponent("enterprise-usage.json"))
    }
}

@MainActor
final class MaxController: UsageController {
    let profile = Profile.max
    let session = ClaudeSession(profile: .max)
    let model = MaxModel()
    private let history = HistoryStore(name: "history-max")
    private(set) var lastAttempt = Date.distantPast
    private var busy = false
    private var organization: (uuid: String, plan: String)?

    var status: FetchStatus { model.status }
    var lastSuccess: Date? { model.usage?.fetchedAt }

    init() {
        model.usage = Storage.load(MaxUsage.self, "max-usage")
        model.days = history.dailyIncrements()
    }

    func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        lastAttempt = Date()
        if model.usage == nil { model.status = .loading }
        do {
            try await session.ensureReady()
            if organization == nil {
                organization = MaxParser.pickOrganization(try await session.fetchJSON("/api/organizations"))
            }
            guard let organization else { throw SessionError.unexpected("No claude.ai organization found for this account") }
            let json = try await session.fetchJSON("/api/organizations/\(organization.uuid)/usage")
            guard let usage = MaxParser.parseUsage(json, plan: organization.plan) else {
                throw SessionError.unexpected("claude.ai returned usage in an unexpected format")
            }
            var reading: [String: Double] = [:]
            reading["week"] = usage.weekly?.utilization
            reading["session"] = usage.session?.utilization
            history.record(reading)

            model.usage = usage
            model.days = history.dailyIncrements()
            model.status = .idle
            Storage.save(usage, "max-usage")
        } catch SessionError.signedOut {
            session.invalidate()
            organization = nil
            model.status = .signedOut
        } catch {
            session.invalidate()
            model.status = .error(error.localizedDescription)
        }
    }

    func signOut() async {
        await session.signOut()
        organization = nil
        model.usage = nil
        model.days = []
        model.status = .signedOut
        try? FileManager.default.removeItem(at: Storage.directory.appendingPathComponent("max-usage.json"))
    }
}
