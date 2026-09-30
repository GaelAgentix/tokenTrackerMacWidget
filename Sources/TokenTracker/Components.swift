import SwiftUI

/// Seven-day bar chart in the style of the Screen Time widget: thin bars, dotted guides,
/// axis labels on the right.
struct UsageBarChart: View {
    var days: [DayBar]
    var order: [String]
    var utcDays = false
    var emptyMessage = "Building history…"
    var color: (String) -> Color
    var axisLabel: (Double) -> String
    var minimumScale: Double

    var body: some View {
        let peak = days.map { total($0) }.max() ?? 0
        let top = Self.niceCeiling(Swift.max(peak, minimumScale))
        GeometryReader { geo in
            let axisWidth: CGFloat = 28
            let labelHeight: CGFloat = 11
            let plotWidth = geo.size.width - axisWidth
            let plotHeight = Swift.max(geo.size.height - labelHeight - 3, 10)
            let slot = plotWidth / CGFloat(Swift.max(days.count, 1))
            let barWidth = Swift.min(7, slot * 0.4)

            ZStack(alignment: .topLeading) {
                ForEach(0..<3, id: \.self) { i in
                    let y = plotHeight * CGFloat(i) / 2
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: plotWidth, y: y))
                    }
                    .stroke(Theme.grid, style: StrokeStyle(lineWidth: 0.6, dash: i == 2 ? [] : [1, 2.5]))
                    Text(axisLabel(top * Double(2 - i) / 2))
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize()
                        .position(x: plotWidth + axisWidth / 2 + 2, y: y)
                }

                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    let x = slot * (CGFloat(index) + 0.5)
                    let dayTotal = total(day)
                    let height = dayTotal > 0 ? Swift.max(CGFloat(dayTotal / top) * plotHeight, 2) : 0
                    VStack(spacing: 0) {
                        ForEach(order.reversed().filter { (day.segments[$0] ?? 0) > 0 }, id: \.self) { key in
                            Rectangle()
                                .fill(color(key))
                                .frame(height: height * CGFloat((day.segments[key] ?? 0) / dayTotal))
                        }
                    }
                    .frame(width: barWidth, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: barWidth / 2, style: .continuous))
                    .position(x: x, y: plotHeight - height / 2)

                    Text(Fmt.weekdayInitial(day.date, utc: utcDays))
                        .font(.system(size: 8.5, weight: day.isToday ? .bold : .medium))
                        .foregroundStyle(day.isToday ? Theme.primary : Theme.secondary)
                        .position(x: x, y: plotHeight + 3 + labelHeight / 2)
                }

                if peak == 0 {
                    Text(emptyMessage)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .position(x: plotWidth / 2, y: plotHeight * 0.55)
                }
            }
        }
    }

    private func total(_ day: DayBar) -> Double {
        order.reduce(0) { $0 + (day.segments[$1] ?? 0) }
    }

    static func niceCeiling(_ value: Double) -> Double {
        guard value > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(value)))
        for step in [1.0, 2.0, 2.5, 5.0, 10.0] where step * magnitude >= value {
            return step * magnitude
        }
        return 10 * magnitude
    }
}

/// Thin progress bar with a trailing caption.
struct UsageMeter: View {
    var fraction: Double
    var caption: String

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Capsule()
                        .fill(Theme.level(fraction))
                        .frame(width: Swift.max(4, geo.size.width * CGFloat(Swift.min(fraction, 1))))
                }
            }
            .frame(height: 4)
            Text(caption)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .fixedSize()
        }
    }
}

/// Small rounded-square icon, like the app icons in the Screen Time widget.
struct TileIcon: View {
    var symbol: String
    var color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(color)
            .frame(width: 16, height: 16)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            )
    }
}

/// Circular gauge used for Max plan limits.
struct RingIcon: View {
    var fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(Theme.track, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: CGFloat(Swift.min(Swift.max(fraction, 0.001), 1)))
                .stroke(Theme.level(fraction), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 14, height: 14)
        .frame(width: 16, height: 16)
    }
}

struct SideRow<Icon: View>: View {
    var icon: Icon
    var value: String
    var caption: String?

    var body: some View {
        HStack(spacing: 6) {
            icon
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
            if let caption {
                Text(caption)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct SideHeader: View {
    var title: String
    var status: FetchStatus

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkle")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.claude)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
            if case .error(let message) = status {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Color(hex: 0xF7B32B))
                    .help(message)
            }
        }
    }
}

/// Shown until the account is signed in (or while the first load runs).
struct PromptView: View {
    var title: String
    var status: FetchStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SideHeader(title: title, status: .idle)
            Spacer(minLength: 0)
            switch status {
            case .signedOut, .idle:
                Text("Sign in to start tracking")
                    .font(.system(size: 17, weight: .medium))
                Text("Click to open claude.ai and sign in with this account.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            case .loading:
                Text("Loading usage…")
                    .font(.system(size: 17, weight: .medium))
                Text("Reading claude.ai/settings/usage")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            case .error(let message):
                Text("Couldn't load usage")
                    .font(.system(size: 17, weight: .medium))
                Text("\(message). Click to try again.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
