import StoreKit
import SwiftUI

/// The company's plan: what it covers, where it stands, and the ways to change it. The plan is bought with Apple's purchase
/// sheet and managed in Apple's own subscription screen, so there is no card to enter here.
struct BillingView: View {
    @Environment(AppModel.self) private var model

    @State private var overview: BillingOverview?
    @State private var failure: String?
    @State private var showPlans = false
    @State private var showManage = false
    @State private var isRestoring = false
    @State private var restoreNote: String?

    var body: some View {
        List {
            if let overview {
                planSection(overview)
                peopleSection(overview)
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
        .task {
            await load()
            // Quietly tell the server what this Apple Account holds, so a renewal is noticed even if Apple's own message
            // to the server went astray.
            await model.syncPlanWithStore()
            await load()
        }
        .sheet(isPresented: $showPlans, onDismiss: { Task { await load() } }) { PlanSheet() }
        .manageSubscriptionsSheet(isPresented: $showManage)
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
                if let covered = plan.seatsCovered, plan.required {
                    Text("Covers up to \(covered) people.")
                        .font(.subheadline)
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
                    Text("Free trial ends on \(trialEnd.formatted(date: .abbreviated, time: .omitted)).")
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

    private func peopleSection(_ overview: BillingOverview) -> some View {
        let seats = overview.seats
        return Section {
            LabeledContent("People on the team", value: "\(seats.used)")
            if seats.pending > 0 {
                LabeledContent("Invited, not joined yet", value: "\(seats.pending)")
            }
            if overview.plan.required, overview.plan.seatsCovered != nil {
                LabeledContent("Places left", value: "\(seats.remaining)")
            }
        } header: {
            Text("People")
        } footer: {
            if overview.plan.required {
                if let covered = overview.plan.seatsCovered {
                    Text("Your plan covers up to \(covered) people, counting open invites. When you're full, move to the next plan: Apple charges only the difference for the rest of the period.")
                } else {
                    Text("A plan covers up to \(model.teamConfig.seatMinimum) people to start, and bigger ones cover more.")
                }
            }
        }
            .listRowBackground(Color.slateCard)
    }

    private func actionSection(_ overview: BillingOverview) -> some View {
        let hasPlan = overview.plan.status != .none && overview.plan.status != .canceled
        return Section {
            Button {
                showPlans = true
            } label: {
                Text(hasPlan ? "Change plan" : "Choose a plan")
                    .frame(minHeight: Metrics.minTapTarget)
            }
            if hasPlan {
                Button {
                    showManage = true
                } label: {
                    Text("Manage subscription")
                        .frame(minHeight: Metrics.minTapTarget)
                }
            }
            Button {
                Task { await restore() }
            } label: {
                HStack {
                    Text("Restore Purchases")
                    if isRestoring { Spacer(); ProgressView() }
                }
                .frame(minHeight: Metrics.minTapTarget)
            }
            .disabled(isRestoring)
        } footer: {
            VStack(alignment: .leading, spacing: Space.xs) {
                if let restoreNote { Text(restoreNote) }
                Text("Apple handles payment: Apple Pay, a card in your Wallet or your Apple Account balance. Slate Pro never sees your card. Manage Subscription opens Apple's own screen to change the payment method or cancel. If you subscribed on another phone, Restore Purchases finds it.")
            }
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

    private func restore() async {
        isRestoring = true
        defer { isRestoring = false }
        restoreNote = nil
        do {
            let found = try await model.restorePlan()
            restoreNote = found ? "Your plan is active." : "No plan for this company was found on this Apple Account."
            await load()
        } catch {
            model.show(error, title: "Couldn't restore")
        }
    }
}
