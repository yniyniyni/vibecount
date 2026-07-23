import SwiftUI
import Charts

/// The user's own usage, broken down by day (30-day bar chart) and by model.
/// Reads the latest breakdown from the environment; shows an empty state when
/// there's no usage yet. Optional environment so it still renders in tests and
/// previews without the object (mirrors DashboardView's SyncStatus? handling).
struct StatsView: View {
    @Environment(UsageStats.self) private var stats: UsageStats?
    /// The day currently under the cursor in the chart, and where the cursor is,
    /// so the detail tooltip can follow it. Cleared when the cursor leaves.
    @State private var selectedDay: Date?
    @State private var hoverLocation: CGPoint = .zero

    /// Effective per-model rates. Phase B swaps this for the environment `Rates`.
    private var rateTable: RateTable { DefaultRates.table }

    var body: some View {
        if let breakdown = stats?.breakdown, breakdown.monthly > 0 {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    costSection(breakdown)
                    dailySection(breakdown)
                    modelSection(breakdown)
                }
                .padding()
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("No usage recorded yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // Estimated spend: today and the 30-day total.
    private func costSection(_ breakdown: UsageBreakdown) -> some View {
        let today = Calendar.current.startOfDay(for: Date())
        return VStack(alignment: .leading, spacing: 6) {
            Text("Estimated cost")
                .font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                costTile("Today", breakdown.cost(on: today, table: rateTable))
                Spacer()
                costTile("30 days", breakdown.totalCost(table: rateTable))
            }
            Text("Estimated · rates are editable")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func costTile(_ label: String, _ amount: Double) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(amount.formattedUSD).font(.headline).fontDesign(.rounded)
        }
    }

    // 30-day continuous axis, zero-filled so gaps render as empty days.
    private func dailySection(_ breakdown: UsageBreakdown) -> some View {
        let days = Self.last30Days()
        let byDay = breakdown.byDay
        return VStack(alignment: .leading, spacing: 6) {
            Text("Tokens / day")
                .font(.caption).foregroundStyle(.secondary)
            Chart {
                ForEach(days, id: \.self) { day in
                    BarMark(
                        x: .value("Day", day, unit: .day),
                        y: .value("Tokens", byDay[day] ?? 0))
                }
                if let selectedDay {
                    RuleMark(x: .value("Day", selectedDay, unit: .day))
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month().day())
                }
            }
            .chartYAxis {
                // Compact token labels ("100M") instead of Swift Charts' default
                // scientific notation ("1.0E8").
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let raw = value.as(Double.self) {
                            Text(Int(raw).formattedTokenCount)
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    // Transparent catcher tracks the cursor and maps its x to a day.
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                updateSelection(at: location, proxy: proxy, geo: geo, days: days)
                            case .ended:
                                selectedDay = nil
                            }
                        }

                    if let selectedDay {
                        let detail = dayDetail(for: selectedDay, breakdown: breakdown)
                        tooltip(detail)
                            .position(Self.tooltipCenter(
                                location: hoverLocation,
                                container: geo.size,
                                rowCount: max(detail.models.count, 1)))
                            .allowsHitTesting(false)   // never steal the hover
                    }
                }
            }
            .frame(height: 140)
        }
    }

    private func modelSection(_ breakdown: UsageBreakdown) -> some View {
        let rows = breakdown.byModel.sorted { $0.value > $1.value }
        let maxTokens = rows.first?.value ?? 1
        let costs = breakdown.costByModel(table: rateTable)
        return VStack(alignment: .leading, spacing: 6) {
            Text("By model")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(rows, id: \.key) { label, tokens in
                HStack(spacing: 8) {
                    Text(label).frame(width: 60, alignment: .leading).lineLimit(1)
                    GeometryReader { geo in
                        Capsule()
                            .fill(Color.accentColor.opacity(0.7))
                            .frame(width: maxTokens > 0 ? geo.size.width * CGFloat(tokens) / CGFloat(maxTokens) : 0)
                            .frame(maxHeight: .infinity, alignment: .leading)
                    }
                    .frame(height: 10)
                    Text(tokens.formattedTokenCount)
                        .font(.caption).fontDesign(.monospaced)
                        .frame(width: 48, alignment: .trailing)
                    Text((costs[label] ?? 0).formattedUSD)
                        .font(.caption).fontDesign(.monospaced).foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                }
            }
        }
    }

    // MARK: - Hover tooltip

    /// A single day's detail: total tokens/cost plus its per-model rows, desc.
    struct DayDetail {
        let day: Date
        let total: Int
        let cost: Double
        let models: [(label: String, tokens: Int, cost: Double)]
    }

    private func dayDetail(for day: Date, breakdown: UsageBreakdown) -> DayDetail {
        let tokens = breakdown.models(on: day)
        let costs = breakdown.costByModel(on: day, table: rateTable)
        let sorted = tokens.sorted { $0.value > $1.value }
            .map { (label: $0.key, tokens: $0.value, cost: costs[$0.key] ?? 0) }
        return DayDetail(
            day: day,
            total: tokens.values.reduce(0, +),
            cost: breakdown.cost(on: day, table: rateTable),
            models: sorted)
    }

    private func tooltip(_ detail: DayDetail) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(detail.day, format: .dateTime.month().day())
                .font(.caption.bold())
            Text("\(detail.total.formattedTokenCount) · \(detail.cost.formattedUSD)")
                .font(.caption2).foregroundStyle(.secondary)
            if detail.models.isEmpty {
                Text("No usage").font(.caption2).foregroundStyle(.secondary)
            } else {
                ForEach(detail.models, id: \.label) { model in
                    HStack(spacing: 8) {
                        Text(model.label).font(.caption2)
                        Spacer(minLength: 10)
                        Text(model.tokens.formattedTokenCount)
                            .font(.caption2).fontDesign(.monospaced)
                        Text(model.cost.formattedUSD)
                            .font(.caption2).fontDesign(.monospaced).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(width: Self.tooltipContentWidth, alignment: .leading)
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
        .shadow(radius: 3)
    }

    /// Maps the cursor position to a day within the 30-day window, or clears the
    /// selection when the cursor is off the plot or outside the window.
    private func updateSelection(at location: CGPoint, proxy: ChartProxy, geo: GeometryProxy, days: [Date]) {
        guard let plotFrame = proxy.plotFrame else { return }
        let rect = geo[plotFrame]
        guard rect.contains(location) else { selectedDay = nil; return }
        guard let date: Date = proxy.value(atX: location.x - rect.origin.x) else { return }
        let day = Calendar.current.startOfDay(for: date)
        guard let first = days.first, let last = days.last, day >= first, day <= last else {
            selectedDay = nil
            return
        }
        selectedDay = day
        hoverLocation = location
    }

    // MARK: - Layout helpers (pure — unit tested)

    static let tooltipContentWidth: CGFloat = 185

    /// Centers the tooltip near the cursor: to its right (flipping left near the
    /// right edge) and above it (flipping below near the top), always fully
    /// inside `container`.
    static func tooltipCenter(location: CGPoint, container: CGSize, rowCount: Int) -> CGPoint {
        let width = tooltipContentWidth + 12            // content + padding
        let height = 34 + CGFloat(max(rowCount, 1)) * 14
        let halfW = width / 2, halfH = height / 2

        var x = location.x + halfW + 12
        if x + halfW > container.width { x = location.x - halfW - 12 }  // flip left
        x = min(max(x, halfW + 2), max(halfW + 2, container.width - halfW - 2))

        var y = location.y - halfH - 8
        if y - halfH < 0 { y = location.y + halfH + 8 }                 // flip below
        y = min(max(y, halfH + 2), max(halfH + 2, container.height - halfH - 2))

        return CGPoint(x: x, y: y)
    }

    /// The trailing 30 startOfDay dates, oldest first.
    static func last30Days() -> [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<30).reversed().compactMap {
            calendar.date(byAdding: .day, value: -$0, to: today)
        }
    }
}
