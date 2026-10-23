import SwiftUI

/// Settings, pushed from the Profile tab. The Team section is about the company on screen (or an invitation to start
/// one); the rest is about the person.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var showNotifications = false
    @State private var showUpgrade = false
    @State private var showNewCompany = false
    @State private var confirmLeave = false
    @State private var confirmSignOut = false
    @State private var confirmDelete = false

    var body: some View {
        List {
            if let organization = model.organization {
                companySection(organization)
            } else {
                individualTeamSection
            }

            Section("You") {
                Button {
                    showNotifications = true
                } label: {
                    Label("Notifications", systemImage: "bell")
                        .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                }
                .buttonStyle(.plain)
            }

            Section {
                Button {
                    confirmSignOut = true
                } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                        .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                }
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Delete account…", systemImage: "trash")
                        .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                }
            } footer: {
                Text("Deleting your account removes your own profile and portfolio. It can't be undone.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showNotifications) {
            NotificationSettingsSheet()
                .presentationDetents([.large])
        }
        .sheet(isPresented: $showUpgrade) { UpgradeSheet() }
        .sheet(isPresented: $showNewCompany) { NewCompanySheet() }
        .confirmationDialog("Sign out of Slate?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { Task { await model.signOut() } }
        }
        .confirmationDialog("Delete your account?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Account", role: .destructive) { Task { await model.deleteAccount() } }
        } message: {
            Text(model.accounts.companies.contains { $0.role == .owner }
                 ? "You own a company. Hand it to someone else or close it first; then this permanently deletes your own profile and portfolio."
                 : "This permanently deletes your profile and portfolio. This can't be undone.")
        }
        .confirmationDialog(
            "Leave \(model.organization?.name ?? "this company")?",
            isPresented: $confirmLeave,
            titleVisibility: .visible
        ) {
            Button("Leave Company", role: .destructive) { Task { await leave() } }
        } message: {
            Text("Your upcoming bookings there go back to the team. You keep your own profile and can be invited again.")
        }
    }

    // MARK: Company

    @ViewBuilder
    private func companySection(_ organization: Organization) -> some View {
        Section {
            if let banner = organization.plan.banner {
                planNotice(banner, organization: organization)
            }

            if model.can(.teamView) {
                NavigationLink {
                    MembersView()
                } label: {
                    row("person.2", "Members", detail: seatsText(organization))
                }
            }
            if model.can(.calendarViewTeam) {
                NavigationLink {
                    TeamCalendarView()
                } label: {
                    row("calendar.day.timeline.left", "Team calendar")
                }
            }
            if model.can(.reportsView) {
                NavigationLink {
                    ReportsView()
                } label: {
                    row("chart.bar", "Reports")
                }
            }
            if model.can(.companyEdit) {
                NavigationLink {
                    CompanySettingsView()
                } label: {
                    row("slider.horizontal.3", "Company settings")
                }
            }
            if model.can(.billingManage) {
                NavigationLink {
                    BillingView()
                } label: {
                    row("creditcard", "Billing", detail: organization.plan.status.title)
                }
            }
            if model.can(.activityView) {
                NavigationLink {
                    ActivityView()
                } label: {
                    row("list.bullet.rectangle", "Activity")
                }
            }
            if model.can(.calendarManageOwn) {
                NavigationLink {
                    MyHoursView()
                } label: {
                    row("clock", "My hours here", detail: organization.myHours == nil ? "Company hours" : "Custom")
                }
            }
        } header: {
            Text("Team · \(organization.name)")
        } footer: {
            Text("You're \(articleFor(organization.myRole)) \(organization.myRole.title). \(organization.myRole.summary)")
        }

        Section {
            Button(role: .destructive) {
                confirmLeave = true
            } label: {
                Label("Leave company", systemImage: "rectangle.portrait.and.arrow.right")
                    .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
            }
        } footer: {
            if organization.myRole == .owner {
                Text("As the Owner, hand the company to someone else (in Members) before you can leave it.")
            }
        }
    }

    private var individualTeamSection: some View {
        Section {
            Button {
                showUpgrade = true
            } label: {
                row("building.2", "Upgrade to a company")
            }
            .buttonStyle(.plain)
            Button {
                showNewCompany = true
            } label: {
                row("plus.circle", "Start a new company")
            }
            .buttonStyle(.plain)
        } header: {
            Text("Team")
        } footer: {
            Text("A company has its own page, a team with roles, shared services and one calendar. Your profile, services, bookings and contracts come with you.")
        }
    }

    private func planNotice(_ text: String, organization: Organization) -> some View {
        Label {
            Text(text).font(.subheadline)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.slateWarning)
        }
        .padding(.vertical, Space.xs)
        .accessibilityElement(children: .combine)
    }

    private func row(_ symbol: String, _ title: String, detail: String? = nil) -> some View {
        HStack(spacing: Space.m) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(minWidth: Metrics.iconColumn)
                .accessibilityHidden(true)
            Text(title)
            Spacer(minLength: Space.s)
            if let detail {
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: Metrics.minTapTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func seatsText(_ organization: Organization) -> String {
        let used = organization.seats.used
        return used == 1 ? "1 person" : "\(used) people"
    }

    private func articleFor(_ role: OrgRole) -> String { role == .admin ? "an" : "a" }

    private func leave() async {
        guard let id = model.organization?.id else { return }
        do {
            try await model.leaveCompany(id)
        } catch {
            model.show(error, title: "Couldn't leave")
        }
    }
}
