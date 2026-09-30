import Foundation

/// Cumulative readings (month-to-date spend, weekly utilization…) recorded on every refresh.
/// Day-by-day bars are the increases between consecutive readings, so the chart fills in
/// even when claude.ai only reports running totals.
final class HistoryStore {
    struct Sample: Codable {
        var t: Date
        var v: [String: Double]
    }

    private let name: String
    private(set) var samples: [Sample]

    init(name: String) {
        self.name = name
        samples = Storage.load([Sample].self, name) ?? []
    }

    func record(_ values: [String: Double], at now: Date = Date()) {
        let sample = Sample(t: now, v: values)
        // Keep at most one reading per ~10 minutes; the latest one wins.
        if let last = samples.last, now.timeIntervalSince(last.t) < 9 * 60, samples.count > 1 {
            samples[samples.count - 1] = sample
        } else {
            samples.append(sample)
        }
        let cutoff = now.addingTimeInterval(-45 * 86_400)
        samples.removeAll { $0.t < cutoff }
        Storage.save(samples, name)
    }

    /// Increase per local calendar day over the last `days` days, oldest first.
    /// A drop in a running total means it reset, so the new value is the increase.
    func dailyIncrements(days: Int = 7, now: Date = Date(), calendar: Calendar = .current) -> [DayBar] {
        let today = calendar.startOfDay(for: now)
        let starts = (0..<days).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        var buckets: [Date: [String: Double]] = [:]
        for (a, b) in zip(samples, samples.dropFirst()) {
            let day = calendar.startOfDay(for: b.t)
            guard day >= starts[0] else { continue }
            for (key, value) in b.v {
                guard let previous = a.v[key] else { continue }
                var delta = value - previous
                if delta < -0.0001 { delta = value }
                if delta > 0 { buckets[day, default: [:]][key, default: 0] += delta }
            }
        }
        return starts.map { DayBar(date: $0, segments: buckets[$0] ?? [:], isToday: $0 == today) }
    }

    var hasEnoughData: Bool { samples.count >= 2 }
}
