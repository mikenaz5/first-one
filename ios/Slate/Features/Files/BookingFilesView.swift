import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A booking's photos and videos. The creator side adds files, delivers them and sends revisions; the client previews them,
/// pays the balance to unlock the originals, and saves them before the time is up.
struct BookingFilesView: View {
    @Environment(AppModel.self) private var model

    let bookingID: UUID

    @State private var photoPicks: [PhotosPickerItem] = []
    @State private var showImporter = false
    @State private var viewer: FileViewerTarget?
    @State private var delivering = false
    @State private var removing: DeliveryFile?
    @State private var paymentMessage: String?
    @State private var loadMessage: String?
    @State private var deliveredCount = 0
    @State private var isReading = false

    private var booking: Booking? { model.bookings.first { $0.id == bookingID } }
    private var files: BookingFiles? { model.files(for: bookingID) }

    var body: some View {
        Group {
            if let booking {
                content(booking)
            } else {
                ContentUnavailableView("Booking not found", systemImage: "calendar.badge.exclamationmark")
            }
        }
        .navigationTitle("Photos and videos")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: booking?.status) {
            loadMessage = await model.loadFiles(for: bookingID)
            await model.loadFilesConfig()
            await model.refreshStorageMeter()
        }
    }

    private func content(_ booking: Booking) -> some View {
        let provider = model.addsFiles(to: booking)
        return ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                if let loadMessage {
                    Label(loadMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Color.slateDanger)
                }
                if provider {
                    creatorHeader(booking)
                    uploadsCard
                    if let draft = files?.draft { draftCard(draft, booking) }
                }
                ForEach(files?.delivered ?? []) { delivery in
                    deliveryCard(delivery, booking: booking, provider: provider)
                }
                if !provider, files?.delivered.isEmpty ?? true, loadMessage == nil {
                    waitingCard(booking)
                }
            }
            .padding(Space.page)
            .frame(maxWidth: Metrics.pageWidth)
            .frame(maxWidth: .infinity)
        }
        .slatePageBackground()
        .refreshable {
            loadMessage = await model.loadFiles(for: bookingID)
            await model.reloadMoney()
        }
        .fullScreenCover(item: $viewer) { target in
            FileViewer(bookingID: bookingID, target: target)
        }
        .sheet(isPresented: $delivering) {
            if let draft = files?.draft {
                DeliverFilesSheet(booking: booking, draft: draft) { deliveredCount += 1 }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.image, .movie], allowsMultipleSelection: true) { result in
            let picked = FileImport.pickedFiles(from: result)
            Task { await model.addFiles(picked, to: booking) }
        }
        .onChange(of: photoPicks) { _, items in
            guard !items.isEmpty else { return }
            photoPicks = []
            Task { await addFromPhotos(items, to: booking) }
        }
        .confirmationDialog("Remove this file?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let file = removing { Task { await model.removeFile(file, from: booking) } }
                removing = nil
            }
        } message: {
            Text("It's deleted for \(model.counterpartName(for: booking)) too, and the space it used comes back.")
        }
        .alert("Payment", isPresented: Binding(get: { paymentMessage != nil }, set: { if !$0 { paymentMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(paymentMessage ?? "")
        }
        .sensoryFeedback(.success, trigger: deliveredCount)
    }

    // MARK: Creator

    private func creatorHeader(_ booking: Booking) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if let meter = model.storageMeter ?? files?.meter {
                VStack(alignment: .leading, spacing: Space.s) {
                    HStack {
                        Label("Storage", systemImage: "internaldrive").font(.subheadline.weight(.semibold))
                        Spacer(minLength: Space.s)
                        Text(meter.text).font(.footnote).foregroundStyle(meter.isNearlyFull ? Color.slateWarning : .secondary)
                    }
                    ProgressView(value: meter.fraction)
                        .tint(meter.isNearlyFull ? Color.slateWarning : Color.accentColor)
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
            }
            if let files, !files.canDeliverFiles, !files.canSendRevision, files.deliveries.isEmpty {
                Label(booking.deliveryURL != nil
                      ? "You already shared a link for this booking, so the first delivery can't be sent as files."
                      : "Files can be added once the shoot has started.",
                      systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if files?.canDeliverFiles == true || files?.canSendRevision == true {
                addMenu(booking)
            }
        }
        .card()
    }

    private func addMenu(_ booking: Booking) -> some View {
        let revision = files?.canSendRevision == true
        return HStack(spacing: Space.m) {
            PhotosPicker(selection: $photoPicks, matching: .any(of: [.images, .videos]), photoLibrary: .shared()) {
                Label(revision ? "Add to revision" : "Add from Photos", systemImage: "photo.on.rectangle.angled")
                    .frame(maxWidth: .infinity, minHeight: Metrics.buttonLabelHeight)
            }
            .buttonStyle(.slatePrimary)
            .controlSize(.large)
            Button {
                showImporter = true
            } label: {
                Label("Files", systemImage: "folder")
                    .frame(minHeight: Metrics.buttonLabelHeight)
            }
            .buttonStyle(.slateOutline)
            .controlSize(.large)
            .accessibilityLabel("Add from the Files app")
        }
    }

    @ViewBuilder
    private var uploadsCard: some View {
        let items = model.uploads(for: bookingID)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Space.m) {
                Text("Sending").eyebrow()
                ForEach(items) { item in
                    UploadRow(item: item)
                }
            }
            .card()
        }
    }

    private func draftCard(_ draft: FileDelivery, _ booking: Booking) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack {
                Text(draft.kind == .revision ? "Revision, not sent yet" : "Ready to deliver").eyebrow()
                Spacer(minLength: Space.s)
                if !draft.liveFiles.isEmpty { Text(draft.countText).font(.footnote).foregroundStyle(.secondary) }
            }
            if draft.liveFiles.isEmpty {
                Text("Add photos and videos. \(model.counterpartName(for: booking)) sees nothing until you deliver.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                FileGrid(delivery: draft, bookingID: bookingID, onRemove: { removing = $0 }) { file in
                    viewer = FileViewerTarget(deliveryID: draft.id, fileID: file.id)
                }
                Button {
                    delivering = true
                } label: {
                    Label(draft.kind == .revision ? "Send revision" : "Deliver", systemImage: "paperplane")
                        .frame(maxWidth: .infinity, minHeight: Metrics.buttonLabelHeight)
                }
                .buttonStyle(.slatePrimary)
                .controlSize(.large)
                .disabled(draft.isUploading || draft.readyFiles.isEmpty || !model.uploads(for: bookingID).isEmpty)
                if draft.isUploading || !model.uploads(for: bookingID).isEmpty {
                    Text("Deliver turns on when everything has finished sending.").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .card()
    }

    // MARK: Both sides

    private func deliveryCard(_ delivery: FileDelivery, booking: Booking, provider: Bool) -> some View {
        let now = model.clock()
        let expired = delivery.isExpired(at: now)
        return VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text(delivery.heading).font(.headline)
                Spacer(minLength: Space.s)
                Text(delivery.countText).font(.footnote).foregroundStyle(.secondary)
            }
            Label(availability(delivery, now: now, booking: booking, provider: provider),
                  systemImage: expired ? "clock.badge.xmark" : "clock")
                .font(.footnote)
                .foregroundStyle(expired ? Color.slateWarning : .secondary)

            if !delivery.note.isEmpty {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(provider ? "Your note" : "Note from \(booking.creatorName)").font(.footnote).foregroundStyle(.secondary)
                    Text(delivery.note).font(.subheadline).textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
            }

            if !expired {
                FileGrid(delivery: delivery, bookingID: bookingID, onRemove: provider ? { removing = $0 } : nil) { file in
                    viewer = FileViewerTarget(deliveryID: delivery.id, fileID: file.id)
                }
            }

            if !delivery.readyFiles.isEmpty {
                Label("Saved \(delivery.savedCount) of \(delivery.readyFiles.count)", systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(delivery.savedCount == delivery.readyFiles.count ? Color.slateSuccess : .secondary)
            }

            if !provider, !expired { clientActions(delivery, booking: booking) }
            if provider, !expired, delivery.sequence == 0, let owed = files?.owedCents, owed > 0 {
                Label("\(model.counterpartName(for: booking)) can save the originals once the \(Money.format(owed, code: booking.currencyCode)) balance is paid.",
                      systemImage: "lock")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private func availability(_ delivery: FileDelivery, now: Date, booking: Booking, provider: Bool) -> String {
        guard let end = delivery.expiresAt else { return "" }
        let day = end.formatted(date: .abbreviated, time: .omitted)
        if delivery.isExpired(at: now) {
            return provider
                ? "These files expired on \(day). You can send them again as a revision."
                : "These files expired on \(day). Ask \(booking.creatorName) to send them again."
        }
        if let left = delivery.daysLeft(at: now), left <= 7 {
            return "Available until \(day) · \(left == 1 ? "1 day" : "\(left) days") left"
        }
        return "Available until \(day)"
    }

    @ViewBuilder
    private func clientActions(_ delivery: FileDelivery, booking: Booking) -> some View {
        if delivery.originalsOpen {
            if let run = model.fileSaveRuns[delivery.id] {
                VStack(alignment: .leading, spacing: Space.s) {
                    ProgressView(value: run.fraction)
                    HStack {
                        Text("Saving \(min(run.total, run.done + 1)) of \(run.total)").font(.footnote).foregroundStyle(.secondary)
                        Spacer(minLength: Space.s)
                        Button("Cancel") { model.cancelSaving(delivery) }
                            .font(.footnote)
                            .disabled(run.isCancelled)
                    }
                }
                .accessibilityElement(children: .combine)
            } else if delivery.unsavedCount > 0 {
                Button {
                    Task { await model.saveAll(delivery, bookingID: bookingID) }
                } label: {
                    Label("Save all to Photos", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity, minHeight: Metrics.buttonLabelHeight)
                }
                .buttonStyle(.slatePrimary)
                .controlSize(.large)
            }
        } else if let owed = files?.owedCents, owed > 0, model.canPay(booking, now: model.clock()) == .balance {
            Button {
                Task {
                    paymentMessage = await model.pay(.balance, for: booking).message
                    await model.loadFiles(for: bookingID)
                }
            } label: {
                Label("Pay \(Money.format(owed, code: booking.currencyCode)) to unlock downloads", systemImage: "lock.open")
                    .frame(maxWidth: .infinity, minHeight: Metrics.buttonLabelHeight)
            }
            .buttonStyle(.slatePrimary)
            .controlSize(.large)
            .disabled(model.isPaying)
            Text("Previews are free to look at. The originals unlock as soon as the balance is paid.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func waitingCard(_ booking: Booking) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Label("Waiting for your files", systemImage: "photo.on.rectangle")
                .font(.headline)
            Text("\(booking.creatorName) will deliver your photos and videos here. You'll see previews first.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    // MARK: Picking

    private func addFromPhotos(_ items: [PhotosPickerItem], to booking: Booking) async {
        isReading = true
        defer { isReading = false }
        var skipped = 0
        for item in items {
            guard let media = try? await item.loadTransferable(type: PickedMedia.self) else {
                skipped += 1
                continue
            }
            // One at a time, so a long list never holds many copies of big videos at once.
            await model.addFiles([media.pickedFile], to: booking)
        }
        if skipped > 0 {
            model.alert = ErrorAlert(title: "Some files couldn't be read", message: "\(skipped) of the files you chose couldn't be read, so they weren't added.")
        }
    }
}

// MARK: - One file on its way

private struct UploadRow: View {
    @Environment(AppModel.self) private var model

    let item: FileUploadItem

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: item.isFailed ? "exclamationmark.triangle.fill" : (item.kind?.symbol ?? "doc"))
                .foregroundStyle(item.isFailed ? Color.slateDanger : .secondary)
                .frame(minWidth: Metrics.iconColumn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(item.name).font(.subheadline).lineLimit(1).truncationMode(.middle)
                if item.isFailed {
                    Text(item.statusText).font(.footnote).foregroundStyle(Color.slateDanger)
                    HStack(spacing: Space.m) {
                        Button("Retry") { Task { await model.retryUpload(item.id) } }
                        Button("Remove", role: .destructive) { Task { await model.dismissUpload(item.id) } }
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderless)
                    .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                } else {
                    ProgressView(value: item.fraction)
                        .accessibilityHidden(true)
                    Text(item.statusText).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
