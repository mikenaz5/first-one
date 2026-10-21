import SwiftUI

/// A package as a clean card. The same view serves the creator's list and what clients see.
struct PackageCard: View {
    enum Style {
        /// Creator's own list: shows a "Hidden" badge for drafts.
        case owner
        /// What a client sees: ends with a call to action.
        case client
    }

    let package: ServicePackage
    var style: Style = .client

    private var visibleDeliverables: [String] { Array(package.deliverables.prefix(3)) }
    private var hiddenDeliverableCount: Int { max(0, package.deliverables.count - 3) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            header

            if !package.summary.isEmpty {
                Text(package.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            FlowLayout(spacing: Space.s, lineSpacing: Space.s) {
                TagChip(title: DurationText.short(minutes: package.durationMinutes), symbol: "clock")
                TagChip(title: "Delivered in \(DurationText.turnaround(days: package.turnaroundDays))", symbol: "shippingbox")
                if !package.addOns.isEmpty {
                    TagChip(title: package.addOns.count == 1 ? "1 add-on" : "\(package.addOns.count) add-ons", symbol: "plus.circle")
                }
            }

            if !visibleDeliverables.isEmpty {
                VStack(alignment: .leading, spacing: Space.s) {
                    ForEach(Array(visibleDeliverables.enumerated()), id: \.offset) { _, item in
                        Label {
                            Text(item).font(.subheadline)
                        } icon: {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                        }
                    }
                    if hiddenDeliverableCount > 0 {
                        Text("+\(hiddenDeliverableCount) more included")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if style == .client {
                HStack {
                    Spacer()
                    Label("Choose a time", systemImage: "chevron.right")
                        .labelStyle(TrailingIconLabelStyle())
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .card(padding: Space.l, radius: Radius.l)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xs) {
                if let category = package.category {
                    Text(category.title).eyebrow()
                }
                Text(package.name)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if style == .owner && !package.isPublished {
                    Label("Hidden from clients", systemImage: "eye.slash")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.slateWarning)
                }
            }
            Spacer(minLength: Space.m)
            VStack(alignment: .trailing, spacing: Space.xxs) {
                Text(Money.format(package.priceCents, code: package.currencyCode))
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                if package.depositCents > 0 {
                    Text("\(Money.format(package.depositCents, code: package.currencyCode)) deposit")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var accessibilityText: String {
        var text = package.accessibilitySummary
        if !package.deliverables.isEmpty {
            text += ". Includes \(package.deliverables.prefix(3).joined(separator: ", "))"
        }
        if !package.addOns.isEmpty {
            text += ". \(package.addOns.count) optional add-ons"
        }
        if style == .owner && !package.isPublished { text += ". Hidden from clients" }
        return text
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Space.xs) {
            configuration.title
            configuration.icon.font(.footnote.weight(.bold))
        }
    }
}

extension ServicePackage {
    /// Sample data for previews.
    static let sample = ServicePackage(
        id: UUID(), creatorID: UUID(), name: "Wedding day film",
        summary: "Full-day coverage with a cinematic highlight film and the ceremony in full.",
        category: .weddings, priceCents: 240_000, currencyCode: "USD", durationMinutes: 480,
        deliverables: ["4-minute highlight film", "Full ceremony edit", "Drone footage", "Raw audio"],
        turnaroundDays: 21, depositCents: 60_000,
        addOns: [AddOn(kind: .drone, priceCents: 25_000), AddOn(kind: .rush, priceCents: 10_000)],
        isPublished: true, position: 0, createdAt: Date(), updatedAt: Date()
    )
}

#Preview("Package card") {
    ScrollView {
        VStack(spacing: Space.l) {
            PackageCard(package: .sample, style: .client)
            PackageCard(package: .sample, style: .owner)
        }
        .padding(Space.page)
    }
    .slatePageBackground()
}
