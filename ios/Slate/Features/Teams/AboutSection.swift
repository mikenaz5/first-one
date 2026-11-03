import SwiftUI

/// The privacy policy, the terms, and a way to reach support: in Settings for creators and on a client's Profile. Apple wants
/// the privacy policy reachable inside the app as well as on the store page.
struct AboutSection: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(AppConfig.productName) \(short) (\(build))"
    }

    var body: some View {
        Section {
            row("hand.raised", "Privacy Policy", AppConfig.privacyURL)
            row("doc.text", "Terms of Use", AppConfig.termsURL)
            row("questionmark.bubble", "Help and support", AppConfig.supportURL)
            row("envelope", "Email support", AppConfig.supportMailURL)
        } header: {
            Text("About")
        } footer: {
            Text(version)
        }
        .listRowBackground(Color.slateCard)
    }

    private func row(_ symbol: String, _ title: String, _ destination: URL) -> some View {
        Link(destination: destination) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer(minLength: Space.s)
                Image(systemName: "arrow.up.forward")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
    }
}
