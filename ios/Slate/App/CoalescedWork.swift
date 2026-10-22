import Foundation

/// A job that may be asked for many times but should never run twice at once.
///
/// Asking while it runs makes it go round once more when it finishes, so the last request always sees the latest
/// state, and an older run can never finish after a newer one and write stale results over them. Used for syncing
/// reminders and refreshing the conversation list, which several things trigger at about the same moment.
@MainActor
final class CoalescedWork {
    private let work: () async -> Void
    private var running = false
    private var again = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ work: @escaping () async -> Void) {
        self.work = work
    }

    /// Does the job (or asks the run in progress to repeat), and returns once nothing is running.
    func run() async {
        again = true
        if running {
            await idle()
            return
        }
        running = true
        await drain()
    }

    /// Like `run()`, without making the caller wait.
    func request() {
        again = true
        guard !running else { return }
        running = true
        Task { await drain() }
    }

    /// Returns once no run is in progress.
    func idle() async {
        guard running else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func drain() async {
        while again {
            again = false
            await work()
        }
        running = false
        let waiting = waiters
        waiters = []
        for continuation in waiting { continuation.resume() }
    }
}
