import SwiftUI

/// On a booking: where the photos and videos stand, with a way into the full screen. The creator side sees what to do next
/// (add files, deliver, send a revision); the client sees what is ready, until when, and what is still to save.
struct FilesSection: View {
    @Environment(AppModel.self) private var model

    let booking: Booking
    /// Changes when the shoot starts, so this section appears without the person leaving the screen.
    var tick = 0

    private struct Row {
        var headline: String
        var detail: String
        var symbol: String
        var tint: Color
        var action: String
    }

    var body: some View {
        if let row = row(now: model.clock()) {
            Section {
                NavigationLink {
                    BookingFilesView(bookingID: booking.id)
                } label: {
                    HStack(alignment: .top, spacing: Space.m) {
                        Image(systemName: row.symbol)
                            .foregroundStyle(row.tint)
                            .frame(minWidth: Metrics.iconColumn)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            Text(row.headline).font(.headline)
                            Text(row.detail).font(.subheadline).foregroundStyle(.secondary)
                            Text(row.action).font(.subheadline.weight(.semibold)).foregroundStyle(Color.slateAccentText)
                                .padding(.top, Space.xxs)
                        }
                    }
                    .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                    .padding(.vertical, Space.xs)
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Photos and videos")
            }
            .listRowBackground(Color.slateCard)
        }
    }

    // MARK: What to say

    private func row(now: Date) -> Row? {
        let provider = model.addsFiles(to: booking)
        let files = model.files(for: booking.id)
        let client = booking.clientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "your client" : booking.clientName

        if provider {
            guard let files else {
                // Not fetched yet: offer the same first step the link does, so the section doesn't pop in late.
                guard model.canOfferFiles(for: booking, now: now) else { return nil }
                return Row(headline: "Deliver photos and videos", detail: "Add them here. \(client) sees previews at once and saves the originals after paying.",
                           symbol: "photo.on.rectangle.angled", tint: Color.slateWarning, action: "Add files")
            }
            if let draft = files.draft, !draft.liveFiles.isEmpty {
                let what = draft.kind == .revision ? "revision" : "delivery"
                return Row(headline: "\(draft.countText) ready", detail: "Your \(what) isn't visible to \(client) until you deliver it.",
                           symbol: "tray.full", tint: Color.slateWarning, action: draft.isUploading ? "See progress" : "Review and deliver")
            }
            if let first = files.delivered.last(where: { $0.sequence == 0 }) ?? files.delivered.first {
                let expired = first.isExpired(at: now)
                var detail = first.countText
                if !first.readyFiles.isEmpty { detail += " · saved \(first.savedCount) of \(first.readyFiles.count)" }
                if expired { detail += " · expired" } else if let left = first.daysLeft(at: now) { detail += " · \(left) \(left == 1 ? "day" : "days") left" }
                return Row(headline: expired ? "Delivery ended" : "Files delivered", detail: detail,
                           symbol: expired ? "clock.badge.xmark" : "checkmark.circle.fill", tint: expired ? Color.slateWarning : Color.slateSuccess,
                           action: files.canSendRevision ? "Send a revision" : "Manage files")
            }
            if files.canDeliverFiles {
                return Row(headline: "Deliver photos and videos", detail: "Add them here. \(client) sees previews at once and saves the originals after paying.",
                           symbol: "photo.on.rectangle.angled", tint: Color.slateWarning, action: "Add files")
            }
            return nil
        }

        guard let files, let newest = files.delivered.first else { return nil }
        let live = files.delivered.filter { !$0.isExpired(at: now) }
        if live.isEmpty {
            return Row(headline: "Your files expired", detail: "Ask \(booking.creatorName) to send them again.", symbol: "clock.badge.xmark",
                       tint: Color.slateWarning, action: "See details")
        }
        let unsaved = live.reduce(0) { $0 + $1.unsavedCount }
        let locked = files.owedCents > 0 && live.contains { !$0.originalsOpen }
        let end = live.compactMap(\.expiresAt).min().map { $0.formatted(date: .abbreviated, time: .omitted) }
        var detail = newest.countText
        if let end { detail += " · until \(end)" }
        if locked {
            detail += " · pay the balance to unlock downloads"
        } else if unsaved > 0 {
            detail += " · \(unsaved) to save"
        }
        return Row(headline: "Your files are ready", detail: detail, symbol: "photo.on.rectangle.angled.fill",
                   tint: locked ? Color.slateWarning : Color.slateSuccess, action: locked ? "Preview and unlock" : "View files")
    }
}
