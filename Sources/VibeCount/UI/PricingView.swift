import SwiftUI

/// Editor for per-model pricing ($/Mtok per billable category). Seeded from the
/// current effective rates; Save persists only the rows that differ from the
/// shipped defaults, so un-edited models keep tracking future default updates.
struct PricingView: View {
    private let rates: Rates
    private let dismiss: () -> Void
    @State private var rows: [RateRow]

    init(rates: Rates, dismiss: @escaping () -> Void) {
        self.rates = rates
        self.dismiss = dismiss
        _rows = State(initialValue: PricingView.rows(from: rates.table))
    }

    /// One editable model row. `id` is the model label.
    struct RateRow: Identifiable {
        let id: String
        var rates: ModelRates
    }

    private static func rows(from table: RateTable) -> [RateRow] {
        table.keys.sorted().map { RateRow(id: $0, rates: table[$0]!) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Model Pricing").font(.title3.bold())
                Text("Estimated rates in USD per million tokens. Edits apply immediately.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("Model").font(.caption.bold())
                        header("Input"); header("Cached"); header("Cache write"); header("Output")
                    }
                    Divider().gridCellColumns(5)
                    ForEach($rows) { $row in
                        GridRow {
                            Text(row.id).lineLimit(1).frame(width: 96, alignment: .leading)
                            rateField($row.rates.uncachedInput)
                            rateField($row.rates.cachedInput)
                            rateField($row.rates.cacheWrite)
                            rateField($row.rates.output)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            HStack {
                Button("Reset to Defaults") { rows = PricingView.rows(from: DefaultRates.table) }
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520, height: 560)
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.caption.bold()).frame(width: 74, alignment: .trailing)
    }

    private func rateField(_ value: Binding<Double>) -> some View {
        TextField("", value: value, format: .number)
            .multilineTextAlignment(.trailing)
            .textFieldStyle(.roundedBorder)
            .frame(width: 74)
    }

    /// Persist only rows that differ from the shipped defaults.
    private func save() {
        var overrides: RateTable = [:]
        for row in rows where row.rates != DefaultRates.table[row.id] {
            overrides[row.id] = row.rates
        }
        rates.update(overrides)
        dismiss()
    }
}
