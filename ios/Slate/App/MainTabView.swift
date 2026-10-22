import SwiftUI

enum AppTab: Hashable {
    case home, bookings, services, messages, profile
}

/// The five tabs from the spec. Each tab owns its own `NavigationStack`.
/// Bars use the system's default look, so they pick up OS-level design updates automatically.
struct MainTabView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        TabView(selection: $model.selectedTab) {
            HomeView()
                .tabItem { Label("Home", systemImage: "house") }
                .tag(AppTab.home)

            BookingsView()
                .tabItem { Label("Bookings", systemImage: "calendar") }
                .tag(AppTab.bookings)

            ServicesView()
                .tabItem { Label("Services", systemImage: "camera.aperture") }
                .tag(AppTab.services)

            MessagesView()
                .tabItem { Label("Messages", systemImage: "bubble.left.and.bubble.right") }
                .badge(model.unreadMessageCount)
                .tag(AppTab.messages)

            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                .tag(AppTab.profile)
        }
        .sensoryFeedback(.selection, trigger: model.selectedTab)
    }
}
