import SwiftUI

/// How the company is doing: bookings and money over a month or a year, and per person. When payouts are split, what the
/// company owes each person for finished work.
struct ReportsView: View {
    @Environment(AppModel.self) private var model

    @State private var range = ReportRange.thisMonth

    private var report: CompanyReport {
        let names = Dictionary(model.teamMembers.map { ($0.userID, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        let now = model.clock()
        let calendar = model.availability?.calendar ?? Calendar.current
        return CompanyReport.make(
            bookings: model.visibleBookings, names: names,
            range: range.interval(now: now, calendar: calendar), now: now,
            splits: model.organization?.splitEnabled == true,
            currencyCode: model.visibleBookings.first?.currencyCode ?? Money.defaultCurrencyCode
        )
    }

    var body: some View {
        let current = report
        let splits = model.organization?.splitEnabled == true
        let money = { (cents: Int) in Money.format(cents, code: current.currencyCode) }

        List {
            Section {
                Picker("Show", selection: $range.animation(.slateSmooth)) {
                    ForEach(ReportRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            }

            Section {
                LabeledContent("Bookings", value: "\(current.booked)")
                LabeledContent("Finished", value: "\(current.completed)")
                LabeledContent("Still to come", value: "\(current.upcoming)")
                LabeledContent("Cancelled", value: "\(current.cancelled)")
            } header: {
                Text("Bookings")
            }

            Section {
                LabeledContent("Booked", value: money(current.bookedCents))
                LabeledContent("Earned", value: money(current.earnedCents))
                if splits {
                    LabeledContent("Owed to people", value: money(current.owedCents))
                }
            } header: {
                Text("Money")
            } footer: {
                Text("Booked is the price of every confirmed and finished booking that starts in this time; earned is the finished ones.")
            }

            Section {
                if current.lines.isEmpty {
                    Text("Nothing in this time yet.").foregroundStyle(.secondary)
                }
                ForEach(current.lines) { line in
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        HStack {
                            Text(line.name).font(.headline)
                            Spacer(minLength: Space.s)
                            Text(money(line.earnedCents)).font(.subheadline.monospacedDigit())
                        }
                        Text(detail(line, splits: splits, money: money))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, Space.xxs)
                    .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("By person")
            } footer: {
                if splits {
                    Text("Owed is each person's share of the finished work they did, as it was set when the booking was given to them. Slate keeps the ledger; the company pays people itself.")
                }
            }
        }
        .navigationTitle("Reports")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.refresh() }
    }

    private func detail(_ line: CompanyReport.Line, splits: Bool, money: (Int) -> String) -> String {
        let count = line.bookings == 1 ? "1 booking" : "\(line.bookings) bookings"
        var parts = [count]
        if line.completed > 0 { parts.append("\(line.completed) finished") }
        if splits && line.memberID != nil { parts.append("owed \(money(line.owedCents))") }
        return parts.joined(separator: " · ")
    }
}
