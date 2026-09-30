import Foundation

/// Reads the two endpoints behind the Enterprise "Your usage limits" page:
/// `/api/organizations/{org}/usage` (spend vs. limit) and
/// `/api/organizations/{org}/usage/spend` (per-product totals and daily series).
enum EnterpriseParser {
    static func parse(usage: Any, spend: Any?, now: Date = Date()) -> EnterpriseUsage? {
        guard let dict = usage as? [String: Any] else { return nil }
        var spent: Double?
        var limit = 0.0
        if let summary = dict["spend"] as? [String: Any] {
            spent = money(summary["used"])
            limit = money(summary["limit"]) ?? 0
        }
        if spent == nil, let extra = dict["extra_usage"] as? [String: Any], let used = number(extra["used_credits"]) {
            let scale = pow(10, number(extra["decimal_places"]) ?? 2)
            spent = used / scale
            limit = (number(extra["monthly_limit"]) ?? 0) / scale
        }
        guard let spent else { return nil }

        var products: [ProductSpend] = []
        var daily: [String: [String: Double]]?
        if let breakdown = spend as? [String: Any] {
            for total in (breakdown["totals"] as? [[String: Any]]) ?? [] {
                guard let name = total["group"] as? String, let cents = number(total["cost_minor_units"]) else { continue }
                products.append(ProductSpend(name: normalizeProduct(name), amount: cents / 100))
            }
            var days: [String: [String: Double]] = [:]
            for entry in (breakdown["series"] as? [[String: Any]]) ?? [] {
                guard let bucket = entry["bucket"] as? String, let name = entry["group"] as? String,
                      let cents = number(entry["cost_minor_units"]) else { continue }
                days[String(bucket.prefix(10)), default: [:]][normalizeProduct(name), default: 0] += cents / 100
            }
            daily = days
        }
        return EnterpriseUsage(spent: spent, limit: limit, resetsAt: nextMonthUTC(after: now),
                               products: products, daily: daily, fetchedAt: now)
    }

    static func normalizeProduct(_ raw: String) -> String {
        let s = raw.lowercased()
        if s.contains("cowork") || s.contains("co_work") || s.contains("co-work") { return "Cowork" }
        if s.contains("code") { return "Claude Code" }
        if s.contains("chat") || s == "claude_ai" || s == "claude.ai" || s == "web" { return "Chat" }
        return raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Enterprise spend limits reset at the start of each month (UTC).
    static func nextMonthUTC(after now: Date) -> Date? {
        let utc = utcCalendar
        let start = utc.date(from: utc.dateComponents([.year, .month], from: now))
        return start.flatMap { utc.date(byAdding: .month, value: 1, to: $0) }
    }

    /// First and last day of the current UTC month, as the usage page requests them.
    static func currentMonthRange(now: Date = Date()) -> (start: String, end: String)? {
        let utc = utcCalendar
        guard let start = utc.date(from: utc.dateComponents([.year, .month], from: now)),
              let next = utc.date(byAdding: .month, value: 1, to: start),
              let end = utc.date(byAdding: .day, value: -1, to: next) else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = utc
        formatter.timeZone = utc.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return (formatter.string(from: start), formatter.string(from: end))
    }

    static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func money(_ any: Any?) -> Double? {
        guard let dict = any as? [String: Any], let minor = number(dict["amount_minor"]) else { return nil }
        return minor / pow(10, number(dict["exponent"]) ?? 2)
    }

    private static func number(_ any: Any?) -> Double? { (any as? NSNumber)?.doubleValue }
}

/// Reads claude.ai's plan-limit endpoints for a Pro/Max account.
enum MaxParser {
    /// Picks the consumer (Max/Pro) organization from GET /api/organizations.
    static func pickOrganization(_ json: Any) -> (uuid: String, plan: String)? {
        guard let orgs = json as? [[String: Any]], !orgs.isEmpty else { return nil }
        func capabilities(_ org: [String: Any]) -> [String] { (org["capabilities"] as? [String]) ?? [] }
        let org = orgs.first { capabilities($0).contains { $0.contains("claude_max") } }
            ?? orgs.first { capabilities($0).contains { $0.contains("claude_pro") } }
            ?? orgs.first { capabilities($0).contains("chat") }
            ?? orgs[0]
        guard let uuid = org["uuid"] as? String else { return nil }
        return (uuid, planName(org))
    }

    static func planName(_ org: [String: Any]) -> String {
        let tier = ((org["rate_limit_tier"] as? String) ?? "").lowercased()
        let caps = ((org["capabilities"] as? [String]) ?? []).joined(separator: " ")
        if tier.contains("20x") { return "Max 20x" }
        if tier.contains("5x") { return "Max 5x" }
        if tier.contains("max") || caps.contains("claude_max") { return "Max" }
        if tier.contains("pro") || caps.contains("claude_pro") { return "Pro" }
        return "Claude"
    }

    /// GET /api/organizations/{uuid}/usage
    static func parseUsage(_ json: Any, plan: String, now: Date = Date()) -> MaxUsage? {
        guard let dict = json as? [String: Any] else { return nil }
        let usage = MaxUsage(
            session: window(dict["five_hour"]),
            weekly: window(dict["seven_day"]),
            weeklyOpus: window(dict["seven_day_opus"]),
            weeklySonnet: window(dict["seven_day_sonnet"]),
            extra: extraUsage(dict["extra_usage"]),
            planName: plan,
            fetchedAt: now)
        return usage.session == nil && usage.weekly == nil ? nil : usage
    }

    private static func window(_ any: Any?) -> LimitWindow? {
        guard let dict = any as? [String: Any], let value = (dict["utilization"] as? NSNumber)?.doubleValue else { return nil }
        return LimitWindow(utilization: value, resetsAt: parseISO(dict["resets_at"] as? String))
    }

    private static func extraUsage(_ any: Any?) -> LimitWindow? {
        guard let dict = any as? [String: Any], (dict["is_enabled"] as? Bool) == true,
              let value = (dict["utilization"] as? NSNumber)?.doubleValue else { return nil }
        return LimitWindow(utilization: value, resetsAt: nil)
    }

    static func parseISO(_ s: String?) -> Date? {
        guard var s else { return nil }
        // ISO8601DateFormatter rejects microseconds; drop any fractional part.
        if let dot = s.firstIndex(of: "."), let end = s[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            s.removeSubrange(dot..<end)
        }
        return ISO8601DateFormatter().date(from: s)
    }
}
