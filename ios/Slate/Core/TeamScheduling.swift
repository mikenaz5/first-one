import Foundation

// MARK: - What a client's device needs to book a company

/// One person who could take a booking, as a client's device sees them: when they work and when they are taken, and
/// nothing about why.
struct MemberSchedule: Codable, Equatable, Identifiable, Hashable {
    var userID: UUID
    var displayName: String
    /// Their hours: the company's, narrowed by their own.
    var weekly: [DayHours]
    /// Time they can't take a booking, each range already extended by the buffer that follows it.
    var busy: [DateInterval]

    var id: UUID { userID }
}

/// A company's availability: the company's rules (notice, buffer, blackouts), and for each person who could take the
/// booking, their hours and busy time.
struct TeamSchedule: Codable, Equatable {
    var settings: AvailabilitySettings
    var assignmentMode: AssignmentMode
    var members: [MemberSchedule]
    /// Bookings waiting for someone to be chosen, as blocked ranges. They use up a person's time without having one.
    var unassigned: [DateInterval]

    /// The same rules for one named person. A client who picks a person is booking them whatever the company's mode is,
    /// and bookings waiting in the queue don't stand in the way.
    func filtered(to memberID: UUID) -> TeamSchedule {
        var copy = self
        copy.members = members.filter { $0.userID == memberID }
        copy.assignmentMode = .auto
        copy.unassigned = []
        return copy
    }

    /// The form the booking screen already understands.
    var asSchedule: CreatorSchedule {
        CreatorSchedule(settings: settings, bookedRanges: [], externalBusy: [], team: self)
    }
}

// MARK: - Team availability

/// Which start times a company can offer. A time is offered when at least one eligible person is free then; in a company
/// that assigns by hand, only when there are more free people than bookings already waiting at that time. The database's
/// `create_booking` makes the same decision.
enum TeamAvailability {
    static func slots(on day: CalendarDay, durationMinutes: Int, team: TeamSchedule, now: Date) -> [TimeSlot] {
        var free: [Date: Int] = [:]
        var found: [Date: TimeSlot] = [:]
        for member in team.members {
            for slot in memberSlots(member, team: team, on: day, durationMinutes: durationMinutes, now: now) {
                free[slot.start, default: 0] += 1
                found[slot.start] = slot
            }
        }
        let buffer = TimeInterval(team.settings.bufferMinutes) * 60
        return found.values
            .filter { slot in
                let people = free[slot.start] ?? 0
                guard team.assignmentMode == .manual else { return people > 0 }
                let occupied = DateInterval(start: slot.start, end: slot.end.addingTimeInterval(buffer))
                let waiting = team.unassigned.filter { IntervalMath.overlaps($0, occupied) }.count
                return people > waiting
            }
            .sorted { $0.start < $1.start }
    }

    /// The people who could take a booking at exactly this time.
    static func freeMembers(start: Date, durationMinutes: Int, team: TeamSchedule, now: Date) -> [MemberSchedule] {
        let day = CalendarDay(start, calendar: team.settings.calendar)
        return team.members.filter { member in
            memberSlots(member, team: team, on: day, durationMinutes: durationMinutes, now: now).contains { $0.start == start }
        }
    }

    private static func memberSlots(
        _ member: MemberSchedule, team: TeamSchedule, on day: CalendarDay, durationMinutes: Int, now: Date
    ) -> [TimeSlot] {
        var settings = team.settings
        settings.weekly = member.weekly
        let schedule = CreatorSchedule(settings: settings, bookedRanges: member.busy, externalBusy: [])
        return AvailabilityEngine.slots(on: day, durationMinutes: durationMinutes, schedule: schedule, now: now)
    }
}
