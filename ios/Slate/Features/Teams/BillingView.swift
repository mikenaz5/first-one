import AuthenticationServices
import SwiftUI

/// The company's plan: what it costs in seats, where the plan stands, and the Stripe pages that change it.
struct BillingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    @State private var overview: BillingOverview?
    @State private var failure: String?
    @State private var isOpening = false

    var body: some View {
        List {
            if let overview {
                planSection(overview)
                seatsSection(overview)
                if overview.plan.required { actionSection(overview) }
            } else if let failure {
                Section {
                    ContentUnavailableView {
                        Label("Can't load billing", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(failure)
                    } actions: {
                        Button("Try Again") { Task { await load() } }
                    }
                    .listRowBackground(Color.clear)
                }
                    .listRowBackground(Color.slateCard)
            } else {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: Metrics.placeholderCompact)
                        .listRowBackground(Color.clear)
                }
                    .listRowBackground(Color.slateCard)
            }
        }
        .scrollContentBackground(.hidden)
        .slatePageBackground()
        .navigationTitle("Billing")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    // MARK: Sections

    private func planSection(_ overview: BillingOverview) -> some View {
        let plan = overview.plan
        return Section {
            VStack(alignment: .leading, spacing: Space.s) {
                Label {
                    Text(plan.required ? plan.status.title : "No plan needed")
                        .font(.headline)
                } icon: {
                    Image(systemName: plan.isOK ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(plan.isOK ? Color.slateSuccess : Color.slateWarning)
                }
                if let banner = plan.banner {
                    Text(banner).font(.subheadline).foregroundStyle(.secondary)
                } else if !plan.required {
                    Text("This device keeps everything on it, so there's nothing to bill.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if let end = plan.periodEnd {
                    Text("Renews on \(end.formatted(date: .abbreviated, time: .omitted)).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let trialEnd = overview.trialEnd, plan.status == .trialing {
                    Text("Trial ends on \(trialEnd.formatted(date: .abbreviated, time: .omitted)).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, Space.xs)
            .accessibilityElement(children: .combine)
        } header: {
            Text("Plan")
        }
            .listRowBackground(Color.slateCard)
    }

    private func seatsSection(_ overview: BillingOverview) -> some View {
        let seats = overview.seats
        return Section {
            LabeledContent("People on the team", value: "\(seats.used)")
            if seats.pending > 0 {
                LabeledContent("Invited, not joined yet", value: "\(seats.pending)")
            }
            LabeledContent("Seats billed", value: "\(seats.billed)")
            LabeledContent("Smallest plan", value: "\(seats.minimum) seats")
            LabeledContent("Largest team", value: "\(seats.maximum) seats")
        } header: {
            Text("Seats")
        } footer: {
            Text("You pay for each seat. Adding someone charges the rest of this period at once; removing someone lowers your next invoice, with no refund for the period already paid. You're always billed for at least \(seats.minimum) seats.")
        }
            .listRowBackground(Color.slateCard)
    }

    private func actionSection(_ overview: BillingOverview) -> some View {
        let hasPlan = overview.plan.status != .none && overview.plan.status != .canceled
        return Section {
            Button {
                Task { await open(hasPlan ? .portal : .checkout) }
            } label: {
                HStack {
                    Text(hasPlan ? "Manage billing" : "Choose a plan")
                    if isOpening { Spacer(); ProgressView() }
                }
                .frame(minHeight: Metrics.minTapTarget)
            }
            .disabled(isOpening)
        } footer: {
            Text(hasPlan
                 ? "Stripe's pages let you change the card, read invoices, or cancel at the end of the period."
                 : "Stripe collects the card on its own pages. Slate Pro never sees it.")
        }
            .listRowBackground(Color.slateCard)
    }

    // MARK: Actions

    private func load() async {
        do {
            overview = try await model.loadBilling()
            failure = nil
        } catch {
            if overview == nil { failure = error.localizedDescription }
        }
    }

    private func open(_ action: BillingAction) async {
        isOpening = true
        defer { isOpening = false }
        do {
            let url = try await model.beginBilling(action)
            do {
                _ = try await webAuthenticationSession.authenticate(using: url, callbackURLScheme: AppConfig.urlScheme)
            } catch {
                // Closing the page early is fine; Stripe keeps where they got to.
            }
            await model.billingReturned()
            await load()
        } catch {
            model.show(error, title: "Couldn't open billing")
        }
    }
}
