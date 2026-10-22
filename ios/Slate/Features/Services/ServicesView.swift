import SwiftUI

private struct PackageEditorTarget: Identifiable {
    let package: ServicePackage
    var id: UUID { package.id }
}

/// Services tab: the creator's packages and availability.
struct ServicesView: View {
    @Environment(AppModel.self) private var model

    @State private var editing: PackageEditorTarget?
    @State private var showAvailability = false
    @State private var showContracts = false
    @State private var pendingDelete: ServicePackage?

    private let rowInsets = EdgeInsets(top: Space.s, leading: Space.page, bottom: Space.s, trailing: Space.page)

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { showAvailability = true } label: { AvailabilityCard() }
                        .buttonStyle(PressableTileStyle())
                        .listRowInsets(rowInsets)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)

                    Button { showContracts = true } label: { ContractsCard() }
                        .buttonStyle(PressableTileStyle())
                        .listRowInsets(rowInsets)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }

                Section {
                    if model.packages.isEmpty {
                        emptyState
                            .listRowInsets(rowInsets)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(model.packages) { package in
                            Button { editing = PackageEditorTarget(package: package) } label: {
                                PackageCard(package: package, style: .owner)
                            }
                            .buttonStyle(PressableTileStyle())
                            .listRowInsets(rowInsets)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = package }
                                Button(package.isPublished ? "Hide" : "Show", systemImage: package.isPublished ? "eye.slash" : "eye") {
                                    Task { await model.setPublished(package, !package.isPublished) }
                                }
                                .tint(.orange)
                            }
                            .swipeActions(edge: .leading) {
                                Button("Duplicate", systemImage: "plus.square.on.square") {
                                    Task { await model.duplicate(package) }
                                }
                                .tint(.indigo)
                            }
                            .contextMenu {
                                Button("Edit", systemImage: "pencil") { editing = PackageEditorTarget(package: package) }
                                Button("Duplicate", systemImage: "plus.square.on.square") {
                                    Task { await model.duplicate(package) }
                                }
                                Button(package.isPublished ? "Hide from clients" : "Show to clients",
                                       systemImage: package.isPublished ? "eye.slash" : "eye") {
                                    Task { await model.setPublished(package, !package.isPublished) }
                                }
                                Divider()
                                Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = package }
                            }
                        }
                    }
                } header: {
                    SectionHeader("Packages")
                        .textCase(nil)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, Space.page)
                        .listRowInsets(EdgeInsets())
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .slatePageBackground()
            .navigationTitle("Services")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New package", systemImage: "plus") {
                        editing = PackageEditorTarget(package: model.makeNewPackage())
                    }
                }
            }
            .refreshable { await model.refresh() }
            .sheet(item: $editing) { target in
                PackageEditorSheet(package: target.package)
            }
            .navigationDestination(isPresented: $showContracts) {
                ContractsListView()
            }
            .sheet(isPresented: $showAvailability) {
                AvailabilitySheet(initial: model.availability ?? AvailabilitySettings.standard())
            }
            .confirmationDialog(
                "Delete \"\(pendingDelete?.name ?? "")\"?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { package in
                Button("Delete Package", role: .destructive) {
                    Task { await model.deletePackage(package) }
                }
            } message: { _ in
                Text("Bookings you've already received keep their details.")
            }
            .sensoryFeedback(trigger: model.packages.count) { old, new in new > old ? .success : .warning }
        }
    }

    private var emptyState: some View {
        Button {
            editing = PackageEditorTarget(package: model.makeNewPackage())
        } label: {
            VStack(spacing: Space.s) {
                Image(systemName: "camera.aperture")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Color.accentColor)
                Text("Create your first package").font(.headline)
                Text("Set a price, what's included and how long it takes. Clients see packages as cards on your page.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 170)
            .padding(.horizontal, Space.l)
            .background(
                RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
            )
            .contentShape(RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
        }
        .buttonStyle(PressableTileStyle())
    }
}

// MARK: - Availability summary card

struct AvailabilityCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: "calendar.badge.clock")
                .font(.title2)
                .foregroundStyle(model.needsAvailability ? Color.slateWarning : Color.accentColor)
                .frame(width: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Availability").font(.headline)
                if let settings = model.availability, settings.hasOpenDay {
                    ForEach(Array(AvailabilityText.lines(for: settings).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if !settings.blackouts.isEmpty {
                        Text(settings.blackouts.count == 1 ? "1 blackout range" : "\(settings.blackouts.count) blackout ranges")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Not set yet. Clients can't book until you add your working hours.")
                        .font(.subheadline)
                        .foregroundStyle(Color.slateWarning)
                }
            }
            Spacer(minLength: Space.s)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .card()
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens working hours, blackout dates and calendar sync")
    }
}

/// Plain-language descriptions of working hours, for cards and summaries.
enum AvailabilityText {
    static func lines(for settings: AvailabilitySettings, calendar: Calendar = .current) -> [String] {
        settings.openDayGroups(firstWeekday: calendar.firstWeekday).map { group in
            let symbols = calendar.shortWeekdaySymbols
            let first = symbols[group.weekdays[0] - 1]
            let days = group.weekdays.count == 1 ? first : "\(first)–\(symbols[group.weekdays[group.weekdays.count - 1] - 1])"
            return "\(days)  \(minute(group.window.startMinute)) – \(minute(group.window.endMinute))"
        }
    }

    static func minute(_ minuteOfDay: Int, calendar: Calendar = .current) -> String {
        let date = calendar.date(from: DateComponents(hour: (minuteOfDay / 60) % 24, minute: minuteOfDay % 60)) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Contracts summary card

struct ContractsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: "doc.text")
                .font(.title2)
                .foregroundStyle(model.hasCreatorSignature && !model.contractTemplates.isEmpty ? Color.accentColor : Color.slateWarning)
                .frame(width: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Contracts").font(.headline)
                if model.contractTemplates.isEmpty {
                    Text("Every booking comes with a contract. Start from a ready-made one.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text(model.contractTemplates.count == 1 ? "1 contract" : "\(model.contractTemplates.count) contracts")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if !model.hasCreatorSignature {
                    Text("Add your signature so clients can sign and book you.")
                        .font(.footnote)
                        .foregroundStyle(Color.slateWarning)
                }
            }
            Spacer(minLength: Space.s)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .card()
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens your contracts and signature")
    }
}
