import SwiftUI
import Charts

/// The user's own usage, broken down by day (30-day bar chart) and by model.
/// Reads the latest breakdown from the environment; shows an empty state when
/// there's no usage yet. Optional environment so it still renders in tests and
/// previews without the object (mirrors DashboardView's SyncStatus? handling).
struct StatsView: View {
    @Environment(UsageStats.self) private var stats: UsageStats?

    var body: some View {
        if let breakdown = stats?.breakdown, breakdown.monthly > 0 {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
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

    // 30-day continuous axis, zero-filled so gaps render as empty days.
    private func dailySection(_ breakdown: UsageBreakdown) -> some View {
        let days = Self.last30Days()
        return VStack(alignment: .leading, spacing: 6) {
            Text("Tokens / day")
                .font(.caption).foregroundStyle(.secondary)
            Chart(days, id: \.self) { day in
                BarMark(
                    x: .value("Day", day, unit: .day),
                    y: .value("Tokens", breakdown.byDay[day] ?? 0))
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month().day())
                }
            }
            .frame(height: 120)
        }
    }

    private func modelSection(_ breakdown: UsageBreakdown) -> some View {
        let rows = breakdown.byModel.sorted { $0.value > $1.value }
        let maxTokens = rows.first?.value ?? 1
        return VStack(alignment: .leading, spacing: 6) {
            Text("By model")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(rows, id: \.key) { label, tokens in
                HStack(spacing: 8) {
                    Text(label).frame(width: 64, alignment: .leading)
                    GeometryReader { geo in
                        Capsule()
                            .fill(Color.accentColor.opacity(0.7))
                            .frame(width: maxTokens > 0 ? geo.size.width * CGFloat(tokens) / CGFloat(maxTokens) : 0)
                            .frame(maxHeight: .infinity, alignment: .leading)
                    }
                    .frame(height: 10)
                    Text(tokens.formattedTokenCount)
                        .font(.caption).fontDesign(.monospaced)
                        .frame(width: 56, alignment: .trailing)
                }
            }
        }
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
