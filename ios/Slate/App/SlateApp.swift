import SwiftUI

@main
struct SlateApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel(backend: BackendFactory.make(), notifications: SystemNotificationCenter(), widget: SystemWidgetPublisher())
    /// The look is dark by default (see `AppearancePreference`); Settings changes it.
    @AppStorage(AppearancePreference.storageKey) private var appearance = AppearancePreference.dark.rawValue

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(AppearancePreference(stored: appearance).colorScheme)
                .task { await delegate.attach(model) }
        }
    }
}
