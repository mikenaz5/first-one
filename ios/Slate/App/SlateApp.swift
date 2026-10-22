import SwiftUI

@main
struct SlateApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel(backend: BackendFactory.make(), notifications: SystemNotificationCenter(), widget: SystemWidgetPublisher())

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await delegate.attach(model) }
        }
    }
}
