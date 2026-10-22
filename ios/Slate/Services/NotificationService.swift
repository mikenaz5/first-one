import UIKit
import UserNotifications

enum NotificationAuthorization: Equatable {
    case notDetermined
    case denied
    case allowed
}

/// The slice of the system's notification center the app uses, so tests can stand in for it.
@MainActor
protocol NotificationCenterClient: AnyObject {
    func authorization() async -> NotificationAuthorization
    /// Shows the system permission prompt the first time. Afterwards it just reports the answer already given.
    func requestAuthorization() async -> Bool
    /// Identifiers of the shoot reminders waiting to fire.
    func pendingReminderIDs() async -> [String]
    func schedule(_ reminder: PlannedReminder) async throws
    func removePending(ids: [String])
    func setBadge(_ count: Int) async
    /// Asks Apple for a device token. The answer arrives at the app delegate.
    func registerForRemoteNotifications()
}

/// The real thing.
@MainActor
final class SystemNotificationCenter: NotificationCenterClient {
    private let center = UNUserNotificationCenter.current()

    func authorization() async -> NotificationAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized, .provisional, .ephemeral: .allowed
        @unknown default: .denied
        }
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func pendingReminderIDs() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(ReminderRules.identifierPrefix) }
    }

    func schedule(_ reminder: PlannedReminder) async throws {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.body
        content.sound = .default
        content.threadIdentifier = "booking-\(reminder.bookingID.uuidString.lowercased())"
        if let url = AppLink.bookingURL(reminder.bookingID) {
            content.userInfo = [NotificationRouting.infoKey: ["url": url.absoluteString]]
        }
        // Pin the zone so the reminder fires at the same moment even if the phone travels to another time zone.
        var parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: reminder.fireDate)
        parts.timeZone = Calendar.current.timeZone
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        try await center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
    }

    func removePending(ids: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    func setBadge(_ count: Int) async {
        try? await center.setBadgeCount(count)
    }

    func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }
}

/// Does nothing and says notifications are off. Used by previews and by tests that don't care about them.
@MainActor
final class InertNotificationCenter: NotificationCenterClient {
    func authorization() async -> NotificationAuthorization { .denied }
    func requestAuthorization() async -> Bool { false }
    func pendingReminderIDs() async -> [String] { [] }
    func schedule(_ reminder: PlannedReminder) async throws {}
    func removePending(ids: [String]) {}
    func setBadge(_ count: Int) async {}
    func registerForRemoteNotifications() {}
}

/// Brings the device's pending shoot reminders in line with a plan: schedules the missing ones and cancels the rest.
@MainActor
enum ReminderScheduler {
    static func sync(_ planned: [PlannedReminder], status: NotificationAuthorization, center: any NotificationCenterClient) async {
        let pending = Set(await center.pendingReminderIDs())
        // Without permission nothing would show anyway, and anything waiting shouldn't linger.
        let wanted = status == .denied ? [] : planned
        let wantedIDs = Set(wanted.map(\.id))

        let stale = pending.subtracting(wantedIDs)
        if !stale.isEmpty { center.removePending(ids: Array(stale)) }
        for reminder in wanted where !pending.contains(reminder.id) {
            try? await center.schedule(reminder)
        }
    }
}
