import Foundation
import Observation

/// State for one booking sheet: which add-ons are chosen, which time is selected, the open times
/// worked out from the creator's schedule, and the contract being reviewed and signed.
@MainActor
@Observable
final class BookingModel {
    enum Phase: Equatable {
        case loading
        case ready
        case noAvailability
        case failed(String)
    }

    enum ContractPhase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    struct DaySlots: Identifiable, Equatable {
        let day: CalendarDay
        let slots: [TimeSlot]
        var id: CalendarDay { day }
    }

    let creator: CreatorProfile
    let package: ServicePackage
    /// For a company: the people a client could book directly, and who offers this package among them.
    private(set) var team: [PublicTeamMember]
    private var offeredBy: [UUID] = []
    /// The person the client chose, or nil to go to whoever is free.
    private(set) var selectedMemberID: UUID?

    private(set) var phase: Phase = .loading
    private(set) var days: [DaySlots] = []
    private(set) var soonest: [TimeSlot] = []
    private(set) var formatter = SlotFormatter(timeZone: .current)
    private(set) var isSubmitting = false
    /// Set once the deposit (if any) is paid and the booking is confirmed.
    private(set) var confirmed: Booking?
    private(set) var signedContract: Contract?
    /// Signed and booked, but the deposit isn't paid yet, so the time is only held.
    private(set) var heldBooking: Booking?
    /// Why the last payment attempt didn't finish, in plain words.
    private(set) var payNotice: String?

    private(set) var contractPhase: ContractPhase = .idle
    private(set) var contractPreview: ContractPreview?
    let capture: SignatureCapture

    var selectedAddOnIDs: Set<UUID> = []
    var selectedSlot: TimeSlot?
    var notes = ""
    /// A message shown above the times, for example after someone else took the slot first.
    var notice: String?

    private var schedule: CreatorSchedule?
    private var now = Date()

    init(creator: CreatorProfile, package: ServicePackage, signerName: String = "", team: [PublicTeamMember] = [], memberID: UUID? = nil) {
        self.creator = creator
        self.package = package
        self.team = team
        selectedMemberID = memberID
        capture = SignatureCapture(fullName: signerName)
    }

    // MARK: Derived

    var chosenAddOns: [AddOn] { package.addOns.filter { selectedAddOnIDs.contains($0.id) } }
    var summary: PriceSummary { PriceSummary.make(package: package, addOns: chosenAddOns) }

    var selectedDay: CalendarDay? {
        guard let slot = selectedSlot, let schedule else { return nil }
        return CalendarDay(slot.start, calendar: schedule.settings.calendar)
    }

    var slotsForSelectedDay: [TimeSlot] {
        guard let day = selectedDay else { return days.first?.slots ?? [] }
        return days.first { $0.day == day }?.slots ?? []
    }

    var referenceDate: Date { now }

    /// The people who could take this booking, when the client may choose one.
    var choosableTeam: [PublicTeamMember] {
        offeredBy.isEmpty ? team : team.filter { offeredBy.contains($0.userID) }
    }

    var canChoosePerson: Bool { creator.kind == .company && !choosableTeam.isEmpty }

    /// Whatever has to change before the person can sign, in plain words. Nil when they can.
    var signBlocker: String? {
        if selectedSlot == nil { return "Choose a time first." }
        if contractPreview == nil { return "The contract hasn't loaded yet." }
        if !capture.isReady {
            return capture.method == .drawn && capture.trimmedName.count >= SignatureRules.nameLength.lowerBound
                ? "Draw your signature to continue."
                : "Add your full name to sign."
        }
        return nil
    }

    // MARK: Loading times

    func load(using model: AppModel, showSpinner: Bool = true) async {
        if showSpinner { phase = .loading }
        do {
            if creator.kind == .company, offeredBy.isEmpty {
                offeredBy = (try? await model.backend.loadPackageMembers(packageID: package.id)) ?? []
            }
            let loaded = try await model.loadSchedule(for: creator, package: package, memberID: selectedMemberID)
            schedule = loaded
            formatter = SlotFormatter(settings: loaded.settings)
            now = Date()
            recompute()
            phase = days.isEmpty ? .noAvailability : .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Works out open days for the current length of booking (add-ons can lengthen it) and
    /// keeps the selected time if it still fits; otherwise falls forward to the next opening.
    private func recompute() {
        guard let schedule else { return }
        let found = AvailabilityEngine.availableDays(
            durationMinutes: summary.durationMinutes,
            schedule: schedule,
            now: now
        )
        days = found.map { DaySlots(day: $0.day, slots: $0.slots) }
        soonest = days.prefix(4).compactMap { $0.slots.first }

        if let current = selectedSlot {
            if let match = days.lazy.flatMap(\.slots).first(where: { $0.start == current.start }) {
                selectedSlot = match // Same start, but the end may have moved with the add-on.
            } else {
                selectedSlot = days.first?.slots.first
                if selectedSlot != nil {
                    notice = "That time no longer fits your choices, so we picked the next opening."
                }
            }
        } else {
            // The earliest opening is preselected, which is what keeps booking to a couple of taps.
            selectedSlot = days.first?.slots.first
        }
    }

    // MARK: Choices

    /// Anything the contract was filled in from has changed, so what was shown is stale.
    private func invalidateContract() {
        contractPreview = nil
        contractPhase = .idle
    }

    func toggle(_ addOn: AddOn) {
        if selectedAddOnIDs.contains(addOn.id) {
            selectedAddOnIDs.remove(addOn.id)
        } else {
            selectedAddOnIDs.insert(addOn.id)
        }
        notice = nil
        invalidateContract()
        recompute()
        if phase == .ready, days.isEmpty { phase = .noAvailability }
    }

    /// Switches between a named person and whoever is free. Their open times differ, so the times are worked out again.
    func selectMember(_ id: UUID?, using model: AppModel) async {
        guard id != selectedMemberID else { return }
        selectedMemberID = id
        selectedSlot = nil
        notice = nil
        invalidateContract()
        await load(using: model, showSpinner: false)
    }

    func selectDay(_ day: CalendarDay) {
        notice = nil
        invalidateContract()
        selectedSlot = days.first { $0.day == day }?.slots.first
    }

    func select(_ slot: TimeSlot) {
        notice = nil
        invalidateContract()
        selectedSlot = slot
    }

    // MARK: Contract

    private func makeRequest(for slot: TimeSlot) -> BookingRequest {
        BookingRequest(
            creatorID: creator.id,
            packageID: package.id,
            addOnIDs: Array(selectedAddOnIDs),
            startAt: slot.start,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            memberID: selectedMemberID
        )
    }

    /// Fetches the contract as the backend fills it in for the current choices.
    func loadContract(using model: AppModel) async {
        guard let slot = selectedSlot else { return }
        contractPhase = .loading
        do {
            contractPreview = try await model.previewContract(for: makeRequest(for: slot))
            contractPhase = .ready
        } catch {
            contractPreview = nil
            contractPhase = .failed(error.localizedDescription)
        }
    }

    // MARK: Signing and booking

    /// Signs the contract the person was shown and books. With a deposit the time is held and the payment sheet
    /// follows straight away. Returns true when the booking is confirmed.
    @discardableResult
    func submit(using model: AppModel) async -> Bool {
        guard let slot = selectedSlot, !isSubmitting, heldBooking == nil else { return false }
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            if contractPreview == nil { await loadContract(using: model) }
            guard let preview = contractPreview, capture.isReady else { throw SlateError.invalidSignature }

            let signed = try await model.book(
                makeRequest(for: slot),
                signature: capture.input(documentHash: preview.documentHash)
            )
            signedContract = signed.contract
            if signed.booking.status == .held {
                heldBooking = signed.booking
                await collectDeposit(using: model)
            } else {
                confirmed = signed.booking
            }
            return confirmed != nil
        } catch let error as SlateError where error == .slotTaken || error == .slotUnavailable {
            // Someone else got there first (or the creator's hours changed). Refresh and move on.
            selectedSlot = nil
            invalidateContract()
            await load(using: model, showSpinner: false)
            notice = error.localizedDescription
            return false
        } catch let error as SlateError where error == .contractChanged {
            // The wording changed after it was shown. Show the new version and make them read it again.
            await loadContract(using: model)
            notice = error.localizedDescription
            return false
        } catch {
            model.show(error, title: "Couldn't book")
            return false
        }
    }

    /// Pays the deposit for the held booking (again, if the first try didn't finish).
    func payDeposit(using model: AppModel) async {
        guard heldBooking != nil, !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        await collectDeposit(using: model)
    }

    private func collectDeposit(using model: AppModel) async {
        guard let held = heldBooking else { return }
        payNotice = nil
        switch await model.pay(.deposit, for: held) {
        case .confirmed:
            let latest = model.bookings.first { $0.id == held.id } ?? held
            signedContract = await model.contract(for: latest) ?? signedContract
            heldBooking = nil
            confirmed = latest
        case .processing:
            payNotice = "Your payment went through and is being confirmed. This usually takes a few seconds."
            await refreshHeld(using: model)
        case .cancelled:
            payNotice = "The payment wasn't completed. Your time is still held; pay the deposit to confirm it."
        case .failed(let reason):
            payNotice = reason
            await refreshHeld(using: model)
        }
    }

    /// Looks again at whether the held booking has been paid, expired or cancelled.
    func refreshHeld(using model: AppModel) async {
        guard let held = heldBooking else { return }
        await model.reloadMoney()
        guard let latest = model.bookings.first(where: { $0.id == held.id }) else { return }
        switch latest.status {
        case .confirmed, .completed:
            signedContract = await model.contract(for: latest) ?? signedContract
            heldBooking = nil
            confirmed = latest
        case .held:
            heldBooking = latest
        case .expired, .cancelled:
            heldBooking = latest
        }
    }

    /// Lets go of a held time without paying.
    func abandonHold(using model: AppModel) async {
        guard let held = heldBooking, !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        if await model.cancel(held) != nil {
            heldBooking = nil
            payNotice = nil
            selectedSlot = nil
            invalidateContract()
            await load(using: model, showSpinner: false)
        }
    }
}
