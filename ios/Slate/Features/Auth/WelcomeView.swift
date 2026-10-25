import AuthenticationServices
import CryptoKit
import SwiftUI

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The unhashed nonce for the in-flight request. Apple gets the SHA-256; the backend gets this.
    @State private var rawNonce = ""
    @State private var appeared = false
    @State private var showEmail = false

    var body: some View {
        ZStack {
            AmbientBackground()

            // The page as designed, if it fits; otherwise the same page in a scroll view, so that at the largest
            // text sizes (or on a small phone in landscape) the Continue button can still be reached.
            ViewThatFits(in: .vertical) {
                content
                ScrollView { content }
            }
            .frame(maxWidth: Metrics.readableWidth)
        }
        .sheet(isPresented: $showEmail) { EmailSignInView() }
        .onAppear {
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.slateSpring) { appeared = true }
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            Spacer(minLength: Space.xxl)

            VStack(alignment: .leading, spacing: Space.m) {
                // The mark: a violet rounded tile, the way the reference's logo sits on its splash screen.
                Image(systemName: "camera.aperture")
                    .heroSymbol(34, weight: .regular)
                    .foregroundStyle(Color.slateOnAccent)
                    .frame(width: Metrics.avatarM, height: Metrics.avatarM)
                    .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
                    .accessibilityHidden(true)

                // The last line is the accent, like "connection" in the reference's headline.
                (Text("Get booked.\nGet signed.\n") + Text("Get paid.").foregroundStyle(Color.slateAccentText))
                    .font(SlateFont.display)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                Text("The booking page for photographers, videographers and creators, with a contract in every booking.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .stagger(appeared, index: 0)

            if model.pendingBookingHandle != nil {
                // Someone sent them a booking link: say so, and that signing in is all that's left.
                Label {
                    Text("You've been sent a booking link. Sign in, free, to see their page and book.")
                        .font(.subheadline)
                } icon: {
                    Image(systemName: "link")
                        .foregroundStyle(Color.slateAccentText)
                        .accessibilityHidden(true)
                }
                .card()
                .accessibilityElement(children: .combine)
                .stagger(appeared, index: 1)
            }

            VStack(alignment: .leading, spacing: Space.l) {
                FeatureRow(symbol: "link", title: "One link to share", detail: "Clients pick a package and a time.")
                FeatureRow(symbol: "signature", title: "Contracts built in", detail: "Signed before the booking is confirmed.")
                FeatureRow(symbol: "creditcard.fill", title: "Deposits upfront", detail: "Paid with Apple Pay.")
            }
            .stagger(appeared, index: 1)

            Spacer()

            VStack(spacing: Space.m) {
                SignInWithAppleButton(.continue) { request in
                    let nonce = Nonce.random()
                    rawNonce = nonce
                    request.requestedScopes = [.fullName, .email]
                    request.nonce = Nonce.sha256(nonce)
                } onCompletion: { result in
                    handle(result)
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 54)
                .clipShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
                .accessibilityHint("Creates your account or signs you in")

                Button {
                    showEmail = true
                } label: {
                    Label("Continue with email", systemImage: "envelope")
                        .frame(maxWidth: .infinity, minHeight: Metrics.buttonLabelHeight)
                }
                .buttonStyle(.slateOutline)
                .accessibilityHint("Emails you a six-digit code. No password.")

                #if DEBUG
                if model.isLocalBackend {
                    Button("Continue with a demo account") {
                        Task { await model.signInAsDemo() }
                    }
                    .buttonStyle(.slateOutline)
                    Button("Continue with a demo client") {
                        Task { await model.signInAsDemoClient() }
                    }
                    .buttonStyle(.slateOutline)
                }
                #endif

                Text("By continuing you agree to the Terms and Privacy Policy.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .stagger(appeared, index: 2)
        }
        .padding(.horizontal, Space.page)
        .padding(.bottom, Space.l)
    }

    private func handle(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .failure(let error):
            model.show(error, title: "Couldn't sign in")
        case .success(let authorization):
            guard
                let apple = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = apple.identityToken,
                let token = String(data: tokenData, encoding: .utf8)
            else {
                model.show(SlateError.invalidCredential, title: "Couldn't sign in")
                return
            }
            let credential = AppleCredential(
                userID: apple.user,
                identityToken: token,
                rawNonce: rawNonce,
                fullName: apple.fullName,
                email: apple.email
            )
            Task { await model.signIn(with: credential) }
        }
    }
}

// MARK: - Pieces

private struct FeatureRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            // An icon tile: a violet outline symbol on a dark rounded square with a thin border, as in the reference's categories.
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color.slateAccentText)
                .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                .background(Color.slateFill, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).strokeBorder(Color.slateHairline, lineWidth: 1))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Soft drifting color behind the welcome content. Static when Reduce Motion is on.
private struct AmbientBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false

    var body: some View {
        ZStack {
            Color.slateBackground
            Circle()
                .fill(Color.slateGlow.opacity(0.55))
                .frame(width: 380, height: 380)
                .blur(radius: 90)
                .offset(x: drift ? 90 : -90, y: drift ? -230 : -170)
            Circle()
                .fill(Color.accentColor.opacity(0.22))
                .frame(width: 300, height: 300)
                .blur(radius: 90)
                .offset(x: drift ? -110 : 110, y: drift ? 260 : 200)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) { drift = true }
        }
    }
}

private extension View {
    /// Fades and lifts content in, one block after another.
    func stagger(_ appeared: Bool, index: Int) -> some View {
        opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 16)
            .animation(.slateSpring.delay(Double(index) * 0.08), value: appeared)
    }
}

// MARK: - Nonce

/// Sign in with Apple replay protection: Apple signs the SHA-256 of a random string, and the
/// backend checks the original against the token.
enum Nonce {
    static func random(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        while result.count < length {
            var bytes = [UInt8](repeating: 0, count: 16)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                // Never fall back to a weak generator for a security token.
                preconditionFailure("Unable to generate a secure nonce")
            }
            for byte in bytes where result.count < length {
                // 64 characters, 256 values: every byte maps evenly (no modulo bias).
                result.append(charset[Int(byte) % charset.count])
            }
        }
        return result
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

#Preview("Welcome") {
    WelcomeView()
        .environment(AppModel(backend: LocalBackend(root: FileManager.default.temporaryDirectory.appendingPathComponent("preview-welcome"))))
}
