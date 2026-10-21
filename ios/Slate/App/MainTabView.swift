import SwiftUI

enum AppTab: Hashable {
    case home, bookings, services, messages, profile
}

/// The five tabs from the spec. Each tab owns its own `NavigationStack`.
/// Bars use the system's default look, so they pick up OS-level design updates automatically.
struct MainTabView: View {
    @State private var selection: AppTab = .home

    var body: some View {
        TabView(selection: $selection) {
            HomeView()
                .tabItem { Label("Home", systemImage: "house") }
                .tag(AppTab.home)

            PlaceholderScreen(
                title: "Bookings",
                systemImage: "calendar",
                headline: "No bookings yet",
                message: "Confirmed bookings, with their signed contracts and payments, will appear here."
            )
            .tabItem { Label("Bookings", systemImage: "calendar") }
            .tag(AppTab.bookings)

            PlaceholderScreen(
                title: "Services",
                systemImage: "camera.aperture",
                headline: "Packages come next",
                message: "Create packages, attach contract templates and set your availability here."
            )
            .tabItem { Label("Services", systemImage: "camera.aperture") }
            .tag(AppTab.services)

            PlaceholderScreen(
                title: "Messages",
                systemImage: "bubble.left.and.bubble.right",
                headline: "No messages yet",
                message: "Each booking gets its own conversation with your client."
            )
            .tabItem { Label("Messages", systemImage: "bubble.left.and.bubble.right") }
            .tag(AppTab.messages)

            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                .tag(AppTab.profile)
        }
        .sensoryFeedback(.selection, trigger: selection)
    }
}
