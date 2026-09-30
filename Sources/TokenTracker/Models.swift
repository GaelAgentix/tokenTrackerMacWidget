import Foundation

/// The two claude.ai accounts the widgets track. Each gets its own persistent
/// WebKit data store so both can stay signed in at the same time.
enum Profile: String, CaseIterable {
    case enterprise, max

    var title: String { self == .enterprise ? "Claude Enterprise" : "Claude Max" }
    var shortTitle: String { self == .enterprise ? "Enterprise" : "Max" }

    var storeID: UUID {
        switch self {
        case .enterprise: return UUID(uuidString: "6E1A3C3E-2B7A-4B61-9D51-3E0F5C1A0E01")!
        case .max: return UUID(uuidString: "6E1A3C3E-2B7A-4B61-9D51-3E0F5C1A0E02")!
        }
    }

    /// Row in the desktop widget grid (Weather = 0, Clock/Calendar = 1, Screen Time = 2).
    var defaultRow: Int { self == .enterprise ? 3 : 4 }

    static let usageURL = URL(string: "https://claude.ai/settings/usage")!
    static let loginURL = URL(string: "https://claude.ai/login")!
}

struct ProductSpend: Codable, Hashable {
    var name: String
    var amount: Double
}

struct EnterpriseUsage: Codable {
    var spent: Double
    var limit: Double
    var resetsAt: Date?
    var products: [ProductSpend]
    /// UTC day ("yyyy-MM-dd") -> product -> dollars, when the usage page's own data could be read.
    var daily: [String: [String: Double]]?
    var fetchedAt: Date

    var fraction: Double { limit > 0 ? spent / limit : 0 }
}

struct LimitWindow: Codable {
    /// 0–100, as reported by claude.ai.
    var utilization: Double
    var resetsAt: Date?
}

struct MaxUsage: Codable {
    var session: LimitWindow?
    var weekly: LimitWindow?
    var weeklyOpus: LimitWindow?
    var weeklySonnet: LimitWindow?
    var extra: LimitWindow?
    var planName: String
    var fetchedAt: Date
}

struct DayBar: Hashable {
    var date: Date
    var segments: [String: Double]
    var isToday: Bool
    var total: Double { segments.values.reduce(0, +) }
}

enum FetchStatus: Equatable {
    case idle, loading, signedOut
    case error(String)
}

@MainActor
final class EnterpriseModel: ObservableObject {
    @Published var usage: EnterpriseUsage?
    @Published var days: [DayBar] = []
    @Published var status: FetchStatus = .idle
}

@MainActor
final class MaxModel: ObservableObject {
    @Published var usage: MaxUsage?
    @Published var days: [DayBar] = []
    @Published var status: FetchStatus = .idle
}

enum Storage {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("TokenTracker", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name + ".json")) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: directory.appendingPathComponent(name + ".json"), options: .atomic)
    }
}
