import SwiftUI

@main
struct SlateApp: App {
    @State private var model = AppModel(backend: BackendFactory.make())

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}
