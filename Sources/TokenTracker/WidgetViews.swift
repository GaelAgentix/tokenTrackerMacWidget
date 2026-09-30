import SwiftUI

struct EnterpriseWidgetView: View {
    @ObservedObject var model: EnterpriseModel

    var body: some View {
        Group {
            if let usage = model.usage {
                content(usage)
            } else {
                PromptView(title: "Enterprise", status: model.status)
            }
        }
        .padding(.horizontal, Theme.horizontalPadding).padding(.vertical, Theme.verticalPadding)
        .frame(width: Theme.widgetSize.width, height: Theme.widgetSize.height)
        .foregroundStyle(Theme.primary)
    }

    private func content(_ usage: EnterpriseUsage) -> some View {
        let products = sortedProducts(usage)
        // Stack every product that appears in the chart, even ones missing from the totals.
        let charted = Set(model.days.flatMap { $0.segments.keys })
        let order = Self.ordered(Set(products.map(\.name)).union(charted))
        return HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Fmt.money(usage.spent))
                        .font(.system(size: 24, weight: .regular))
                        .monospacedDigit()
                    if usage.limit > 0 {
                        Text("of \(Fmt.wholeMoney(usage.limit))")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.secondary)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                UsageMeter(fraction: usage.fraction, caption: usage.limit > 0 ? "\(Fmt.percent(usage.fraction)) used" : "no limit")
                    .padding(.top, 4)
                UsageBarChart(days: model.days, order: order, utcDays: true,
                              emptyMessage: usage.daily == nil ? "Loading daily spend…" : "No spend in the last 7 days",
                              color: Theme.productColor, axisLabel: Fmt.axisMoney, minimumScale: 10)
                    .padding(.top, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 0) {
                SideHeader(title: "Enterprise", status: model.status)
                ForEach(products.prefix(3), id: \.name) { product in
                    Spacer(minLength: 2)
                    SideRow(icon: TileIcon(symbol: Theme.productSymbol(product.name), color: Theme.productColor(product.name)),
                            value: Fmt.money(product.amount), caption: nil)
                        .help(product.name)
                }
                Spacer(minLength: 2)
                SideRow(icon: TileIcon(symbol: "arrow.clockwise", color: Color.white.opacity(0.22)),
                        value: Fmt.reset(usage.resetsAt), caption: nil)
                    .help("Spend limit resets")
            }
            .frame(width: 92, alignment: .leading)
        }
    }

    /// Known products first, in the usage page's order, then anything new.
    private func sortedProducts(_ usage: EnterpriseUsage) -> [ProductSpend] {
        usage.products.sorted { a, b in
            let ia = Theme.productOrder.firstIndex(of: a.name) ?? Int.max
            let ib = Theme.productOrder.firstIndex(of: b.name) ?? Int.max
            return ia == ib ? a.amount > b.amount : ia < ib
        }
    }

    private static func ordered(_ names: Set<String>) -> [String] {
        names.sorted {
            let ia = Theme.productOrder.firstIndex(of: $0) ?? Int.max
            let ib = Theme.productOrder.firstIndex(of: $1) ?? Int.max
            return ia == ib ? $0 < $1 : ia < ib
        }
    }
}

struct MaxWidgetView: View {
    @ObservedObject var model: MaxModel

    var body: some View {
        Group {
            if let usage = model.usage {
                content(usage)
            } else {
                PromptView(title: "Max", status: model.status)
            }
        }
        .padding(.horizontal, Theme.horizontalPadding).padding(.vertical, Theme.verticalPadding)
        .frame(width: Theme.widgetSize.width, height: Theme.widgetSize.height)
        .foregroundStyle(Theme.primary)
    }

    private func content(_ usage: MaxUsage) -> some View {
        let weekly = (usage.weekly?.utilization ?? 0) / 100
        return HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Fmt.percent(weekly))
                        .font(.system(size: 24, weight: .regular))
                        .monospacedDigit()
                    Text("of weekly limit")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                }
                .lineLimit(1)
                UsageMeter(fraction: weekly, caption: "resets \(Fmt.reset(usage.weekly?.resetsAt))")
                    .padding(.top, 4)
                UsageBarChart(days: model.days, order: ["week"], color: { _ in Color.white.opacity(0.88) },
                              axisLabel: Fmt.axisPercent, minimumScale: 10)
                    .padding(.top, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 0) {
                SideHeader(title: usage.planName, status: model.status)
                ForEach(rows(usage), id: \.caption) { row in
                    Spacer(minLength: 2)
                    SideRow(icon: RingIcon(fraction: row.fraction), value: Fmt.percent(row.fraction), caption: row.caption)
                }
                Spacer(minLength: 2)
                SideRow(icon: TileIcon(symbol: "arrow.clockwise", color: Color.white.opacity(0.22)),
                        value: Fmt.reset(usage.session?.resetsAt), caption: nil)
                    .help("Current 5-hour session resets")
            }
            .frame(width: 96, alignment: .leading)
        }
    }

    private struct LimitRow { var fraction: Double; var caption: String }

    private func rows(_ usage: MaxUsage) -> [LimitRow] {
        var rows: [LimitRow] = []
        if let s = usage.session { rows.append(LimitRow(fraction: s.utilization / 100, caption: "session")) }
        if let s = usage.weeklySonnet { rows.append(LimitRow(fraction: s.utilization / 100, caption: "Sonnet")) }
        if let o = usage.weeklyOpus, o.utilization > 0 || usage.weeklySonnet == nil {
            rows.append(LimitRow(fraction: o.utilization / 100, caption: "Opus"))
        }
        if let e = usage.extra { rows.append(LimitRow(fraction: e.utilization / 100, caption: "extra")) }
        return Array(rows.prefix(3))
    }
}
