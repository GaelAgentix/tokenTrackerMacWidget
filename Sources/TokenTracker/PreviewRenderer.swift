import AppKit
import SwiftUI

/// `TokenTracker --render-preview out.png` draws both widgets with sample data;
/// `TokenTracker --parse-page page-text.txt` runs the Enterprise parser on a saved page.
@MainActor
enum PreviewRenderer {
    static func render(to path: String) {
        let now = Date()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int, _ segments: [String: Double]) -> DayBar {
            DayBar(date: calendar.date(byAdding: .day, value: -offset, to: today)!, segments: segments, isToday: offset == 0)
        }

        let enterprise = EnterpriseModel()
        enterprise.usage = EnterpriseUsage(
            spent: 411.64, limit: 500, resetsAt: now.addingTimeInterval(3 * 3600 + 720),
            products: [ProductSpend(name: "Claude Code", amount: 380.01),
                       ProductSpend(name: "Chat", amount: 19.26),
                       ProductSpend(name: "Cowork", amount: 12.36)],
            daily: nil, fetchedAt: now)
        enterprise.days = [
            day(6, ["Claude Code": 3, "Chat": 1]), day(5, ["Claude Code": 240, "Chat": 4]),
            day(4, ["Claude Code": 72, "Chat": 3, "Cowork": 9]), day(3, [:]), day(2, [:]),
            day(1, ["Claude Code": 52]), day(0, ["Claude Code": 6, "Cowork": 1.5]),
        ]

        let max = MaxModel()
        max.usage = MaxUsage(
            session: LimitWindow(utilization: 12, resetsAt: now.addingTimeInterval(2 * 3600 + 840)),
            weekly: LimitWindow(utilization: 34, resetsAt: now.addingTimeInterval(1.6 * 86_400)),
            weeklyOpus: nil,
            weeklySonnet: LimitWindow(utilization: 21, resetsAt: nil),
            extra: nil, planName: "Max 20x", fetchedAt: now)
        max.days = [day(6, ["week": 4]), day(5, ["week": 9]), day(4, ["week": 2]), day(3, [:]),
                    day(2, ["week": 6]), day(1, ["week": 11]), day(0, ["week": 2])]

        let signedOut = MaxModel()
        signedOut.status = .signedOut

        let tile = { (view: AnyView) in
            view.background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(Color(hex: 0x113F5F))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)))
        }
        let content = VStack(spacing: 19) {
            tile(AnyView(EnterpriseWidgetView(model: enterprise)))
            tile(AnyView(MaxWidgetView(model: max)))
            tile(AnyView(MaxWidgetView(model: signedOut)))
        }
        .padding(24)
        .background(LinearGradient(colors: [Color(hex: 0x2A8BC4), Color(hex: 0x1D5E8C)], startPoint: .top, endPoint: .bottom))
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            print("Rendering failed")
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("Wrote \(path)")
    }

    /// Runs the Enterprise parser on a captures folder (…/captures/enterprise).
    static func parseCaptures(in directory: String) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        func json(_ suffix: String) -> Any? {
            guard let name = files.first(where: { $0.hasSuffix(suffix) }),
                  let data = FileManager.default.contents(atPath: (directory as NSString).appendingPathComponent(name))
            else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }
        guard let usageJSON = json("_usage.json"),
              let usage = EnterpriseParser.parse(usage: usageJSON, spend: json("_usage_spend.json")) else {
            print("No spend found in \(directory)")
            return
        }
        print("spent:", usage.spent, "limit:", usage.limit, "resets:", usage.resetsAt.map { "\($0)" } ?? "nil")
        usage.products.forEach { print("  \($0.name): \($0.amount)") }
        usage.daily?.sorted { $0.key < $1.key }.suffix(7).forEach { print("  \($0.key): \($0.value)") }
    }
}
