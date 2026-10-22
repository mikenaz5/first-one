import Foundation
import WidgetKit

/// Hands the widget what it should show.
protocol WidgetPublisher: AnyObject {
    func publish(_ snapshot: WidgetSnapshot)
}

/// What tests and previews use: nothing happens.
final class InertWidgetPublisher: WidgetPublisher {
    func publish(_ snapshot: WidgetSnapshot) {}
}

/// Writes the snapshot into the App Group and asks WidgetKit to redraw, but only when something changed (WidgetKit
/// limits how often a widget may be reloaded). Does nothing when the build has no App Group.
final class SystemWidgetPublisher: WidgetPublisher {
    private let directory: URL?
    private let reload: () -> Void
    private var last: WidgetSnapshot?

    init(directory: URL? = WidgetStore.sharedDirectory, reload: @escaping () -> Void = { WidgetCenter.shared.reloadAllTimelines() }) {
        self.directory = directory
        self.reload = reload
    }

    func publish(_ snapshot: WidgetSnapshot) {
        guard let directory else { return }
        if last == nil { last = WidgetStore.read(from: directory) }
        guard last != snapshot else { return }
        do {
            try WidgetStore.write(snapshot, in: directory)
            last = snapshot
            reload()
        } catch {
            // The widget keeps showing what it had; the next change tries again.
        }
    }
}
