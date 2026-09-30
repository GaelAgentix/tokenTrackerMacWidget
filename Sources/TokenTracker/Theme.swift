import SwiftUI

enum Theme {
    // Measured from the native desktop widgets (Weather, Screen Time) on this Mac:
    // medium widgets are 344×164pt with 26pt continuous corners, laid out on a grid with
    // 16pt margins and 16pt gutters starting just below the menu bar.
    static let widgetSize = CGSize(width: 344, height: 164)
    static let cornerRadius: CGFloat = 26
    static let horizontalPadding: CGFloat = 18
    static let verticalPadding: CGFloat = 17
    /// Native widgets darken the wallpaper to a deep navy and keep a bright hairline rim.
    static let glassTint = Color(hex: 0x001A2E, opacity: 0.5)
    static let rim = Color.white.opacity(0.32)

    static let primary = Color.white
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.3)
    static let grid = Color.white.opacity(0.28)
    static let track = Color.white.opacity(0.16)
    static let claude = Color(hex: 0xD97757)

    static let productOrder = ["Claude Code", "Chat", "Cowork"]

    static func productColor(_ name: String) -> Color {
        switch name {
        case "Claude Code": return Color(hex: 0x3D8BEA)
        case "Chat": return Color(hex: 0xE35F33)
        case "Cowork": return Color(hex: 0x21A57A)
        case "Total": return Color.white.opacity(0.85)
        default: return Color(hex: 0x9A8CF0)
        }
    }

    static func productSymbol(_ name: String) -> String {
        switch name {
        case "Claude Code": return "chevron.left.forwardslash.chevron.right"
        case "Chat": return "bubble.left.fill"
        case "Cowork": return "person.2.fill"
        default: return "square.grid.2x2.fill"
        }
    }

    /// Usage level color: calm, then amber from 70%, red from 90%.
    static func level(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.7: return Color(hex: 0x5EB0FF)
        case ..<0.9: return Color(hex: 0xF7B32B)
        default: return Color(hex: 0xFF5F52)
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

enum Fmt {
    private static let usd = Locale(identifier: "en_US")

    static func money(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").locale(usd))
    }

    static func wholeMoney(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").locale(usd).precision(.fractionLength(0)))
    }

    static func axisMoney(_ value: Double) -> String {
        if value == 0 { return "0" }
        if value >= 1000 { return "$\((value / 1000).formatted(.number.precision(.fractionLength(0...1))))k" }
        return "$" + value.formatted(.number.precision(.fractionLength(0...1)))
    }

    static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

    static func axisPercent(_ value: Double) -> String {
        value == 0 ? "0" : "\(value.formatted(.number.precision(.fractionLength(0...1))))%"
    }

    /// "42m", "3h 12m" inside a day, "Thu 3 PM" inside a week, otherwise "Oct 1".
    static func reset(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let seconds = date.timeIntervalSince(now)
        if seconds <= 60 { return "now" }
        if seconds < 86_400 {
            let minutes = Int(seconds / 60)
            return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = seconds < 6 * 86_400 ? "EEE h a" : "MMM d"
        return formatter.string(from: date)
    }

    static func ago(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "never" }
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        if minutes < 1440 { return "\(minutes / 60) hr ago" }
        return "\(minutes / 1440) days ago"
    }

    static func weekdayInitial(_ date: Date, utc: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        if utc { formatter.timeZone = TimeZone(identifier: "UTC") }
        formatter.dateFormat = "EEEEE"
        return formatter.string(from: date)
    }
}
