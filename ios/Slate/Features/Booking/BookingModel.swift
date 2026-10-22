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

    private(set) var phase: Phase = .loading
    private(set) var days: [DaySlots] = []
    private(set) var soonest: [TimeSlot] = []
    private(set) var formatter = SlotFormatter(timeZone: .current)
    private(set) var isSubmitting = false
    private(set) var confirmed: Booking?
    private(set) var signedContract: Contract?

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

    init(creator: CreatorProfile, package: ServicePackage, signerName: String = "") {
        self.creator = creator
        self.package = package
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
            let loaded = try await model.loadSchedule(for: creator.id)
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
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Signs the contract the person was shown and books. Returns true when the booking was made.
    @discardableResult
    func submit(using model: AppModel) async -> Bool {
        guard let slot = selectedSlot, !isSubmitting else { return false }
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            if contractPreview == nil { await loadContract(using: model) }
            guard let preview = contractPreview, capture.isReady else { throw SlateError.invalidSignature }

            let signed = try await model.book(
                makeRequest(for: slot),
                signature: capture.input(documentHash: preview.documentHash)
            )
            confirmed = signed.booking
            signedContract = signed.contract
            return true
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
}
