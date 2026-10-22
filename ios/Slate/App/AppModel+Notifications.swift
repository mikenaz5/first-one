import Foundation

extension AppModel {
    // MARK: - Permission and registration

    var wantsNotificationPrompt: Bool {
        notificationAuthorization == .notDetermined && !notificationPromptDismissed
    }

    func refreshNotificationStatus() async {
        notificationAuthorization = await notifications.authorization()
    }

    /// Runs when the account has loaded: settings, status, a fresh device token if allowed, conversations, reminders.
    func prepareNotifications() async {
        guard let session else { return }
        if let saved = try? await backend.loadNotificationPreferences(for: session.userID) {
            notificationPreferences = saved
        }
        await refreshNotificationStatus()
        if notificationAuthorization == .allowed, backend.sendsPushFromServer {
            // The token can change, so ask on every launch; the answer arrives at `didRegisterForRemoteNotifications`.
            notifications.registerForRemoteNotifications()
        }
        await refreshConversations()
        await syncReminders()
    }

    /// The person chose to turn notifications on: show the system prompt.
    func enableNotifications() async {
        let granted = await notifications.requestAuthorization()
        await refreshNotificationStatus()
        if granted {
            if backend.sendsPushFromServer { notifications.registerForRemoteNotifications() }
            await syncReminders()
        }
    }

    func dismissNotificationPrompt() {
        notificationPromptDismissed = true
        UserDefaults.standard.set(true, forKey: AppConfig.notificationPromptDismissedKey)
    }

    /// Apple gave this device a token: tell the server so it can push here.
    func didRegisterForRemoteNotifications(token: Data) async {
        let hex = DeviceToken.hex(from: token)
        deviceToken = hex
        pushRegistrationProblem = nil
        guard let session, backend.sendsPushFromServer else { return }
        do {
            try await backend.registerDevice(token: hex, environment: .current, for: session.userID)
        } catch {
            pushRegistrationProblem = error.localizedDescription
        }
    }

    func didFailToRegisterForRemoteNotifications(_ error: Error) {
        pushRegistrationProblem = "This build can't receive push notifications yet (\(error.localizedDescription)). See \"Turning on notifications\" in the README."
    }

    /// Before signing out, so the phone stops receiving the previous person's notifications.
    func forgetDevice() async {
        guard let token = deviceToken, backend.sendsPushFromServer else { return }
        try? await backend.unregisterDevice(token: token)
    }

    /// After signing out: nothing of the old account should still be scheduled or showing on the icon.
    func resetNotifications() async {
        conversations = []
        bookingsPath = []
        messagesPath = []
        openConversationID = nil
        notificationPreferences = NotificationPreferences()
        pushRegistrationProblem = nil
        await ReminderScheduler.sync([], status: .denied, center: notifications)
        await notifications.setBadge(0)
    }

    // MARK: - Settings

    func setNotification(_ category: NotificationCategory, enabled: Bool) async {
        guard let session else { return }
        let previous = notificationPreferences
        var updated = previous
        updated[category] = enabled
        notificationPreferences = updated // Show the switch moving straight away.
        do {
            notificationPreferences = try await backend.saveNotificationPreferences(updated, for: session.userID)
        } catch {
            notificationPreferences = previous
            show(error, title: "Couldn't save that")
        }
        if category == .reminders { await syncReminders() }
    }

    // MARK: - Shoot reminders on this device

    /// Brings the reminders scheduled on this phone in line with the bookings, and returns once that is done.
    func syncReminders() async {
        await reminderSync.run()
    }

    /// Returns once no reminder sync is running. For tests.
    func waitForReminderSync() async {
        await reminderSync.idle()
    }

    /// With a server, it queues and sends reminders (so they still arrive if the shoot was cancelled from the other
    /// side, and across devices) and the app schedules nothing of its own. On-device there is no server, so the app
    /// schedules them itself from its bookings. `CoalescedWork` runs this one sync at a time, so an older sync can
    /// never put back a reminder a newer one has just removed.
    func syncRemindersOnce() async {
        guard let session else { return }
        let status = await notifications.authorization()
        notificationAuthorization = status
        let plan = backend.sendsPushFromServer
            ? []
            : ReminderPlanner.plan(bookings: bookings, userID: session.userID, now: clock(), enabled: notificationPreferences.reminders)
        await ReminderScheduler.sync(plan, status: status, center: notifications)
    }

    // MARK: - Notifications arriving

    /// Whether to show a banner for a notification that arrived while the app is open. A message for the conversation
    /// already on screen is visible there, so it doesn't need one.
    func shouldShowBanner(forUserInfo userInfo: [AnyHashable: Any]) -> Bool {
        guard let url = NotificationRouting.url(fromUserInfo: userInfo),
              case .messages(let id?) = AppLink(url: url)
        else { return true }
        return id != openConversationID
    }

    /// A push arrived while the app is open: pick up what it is about.
    func refreshLiveData() async {
        await reloadMoney()
        await refreshConversations()
    }
}
