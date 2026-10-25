import SwiftUI

/// Sign in with an emailed six-digit code: no password, no Apple ID. A new address makes a free client account, and
/// the same address later signs back in, so a repeat client keeps their bookings.
struct EmailSignInView: View {
    private enum Step { case email, code }
    private enum Field { case email, code }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var step = Step.email
    @State private var email = ""
    @State private var code = ""
    @State private var isWorking = false
    @State private var problem: String?
    @State private var sent = 0
    @FocusState private var focus: Field?

    private var cleanEmail: String? { EmailCodeRules.cleanEmail(email) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    switch step {
                    case .email: emailStep
                    case .code: codeStep
                    }
                }
                .padding(.horizontal, Space.page)
                .padding(.top, Space.xl)
                .padding(.bottom, Space.xxl)
                .frame(maxWidth: Metrics.readableWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .slateGlowBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .sensoryFeedback(.success, trigger: sent)
        }
        .interactiveDismissDisabled(isWorking)
        .onAppear { focus = .email }
    }

    // MARK: Steps

    private var emailStep: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            VStack(alignment: .leading, spacing: Space.s) {
                Text("Continue with email")
                    .font(SlateFont.display)
                    .accessibilityAddTraits(.isHeader)
                Text("We'll email you a six-digit code. There's no password. If you've booked before, use the same address to get your bookings back.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: Space.s) {
                field {
                    TextField("you@example.com", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.send)
                        .focused($focus, equals: .email)
                        .onSubmit { Task { await sendCode() } }
                }
                problemText
            }

            primaryButton("Send code", enabled: cleanEmail != nil) { await sendCode() }
        }
    }

    private var codeStep: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            VStack(alignment: .leading, spacing: Space.s) {
                Text("Enter your code")
                    .font(SlateFont.display)
                    .accessibilityAddTraits(.isHeader)
                Text("We sent a six-digit code to \(cleanEmail ?? email). It works for \(EmailCodeRules.lifetimeMinutes) minutes.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                if model.isLocalBackend {
                    Label("Demo mode: no email is sent. Your code is \(EmailCodeRules.demoCode).", systemImage: "info.circle")
                        .font(.subheadline)
                        .foregroundStyle(Color.slateAccentText)
                }
            }

            VStack(alignment: .leading, spacing: Space.s) {
                field {
                    TextField("123456", text: $code)
                        .textContentType(.oneTimeCode)
                        .keyboardType(.numberPad)
                        .font(.title2.monospacedDigit())
                        .focused($focus, equals: .code)
                        .onChange(of: code) { _, _ in
                            problem = nil
                            // Sign in as soon as all six digits are in, whether typed or filled in from Messages.
                            if EmailCodeRules.cleanCode(code) != nil { Task { await verify() } }
                        }
                }
                problemText
            }

            primaryButton("Sign in", enabled: EmailCodeRules.cleanCode(code) != nil) { await verify() }

            VStack(alignment: .leading, spacing: Space.xs) {
                Button("Send a new code") { Task { await sendCode() } }
                    .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                    .disabled(isWorking)
                Button("Use a different email") {
                    code = ""
                    problem = nil
                    step = .email
                    focus = .email
                }
                .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                .disabled(isWorking)
            }
            .font(.subheadline)
        }
    }

    // MARK: Pieces

    private func field<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, Space.m)
            .frame(minHeight: Metrics.minTapTarget)
            .background(Color.slateFill, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).strokeBorder(Color.slateHairline, lineWidth: 1))
    }

    @ViewBuilder
    private var problemText: some View {
        if let problem {
            Text(problem).font(.footnote).foregroundStyle(Color.slateDanger)
        }
    }

    private func primaryButton(_ title: String, enabled: Bool, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack {
                Text(title)
                if isWorking { ProgressView() }
            }
            .frame(maxWidth: .infinity, minHeight: Metrics.buttonLabelHeight)
        }
        .buttonStyle(.slatePrimary)
        .controlSize(.large)
        .disabled(!enabled || isWorking)
    }

    // MARK: Actions

    private func sendCode() async {
        guard let address = cleanEmail, !isWorking else { return }
        isWorking = true
        problem = nil
        defer { isWorking = false }
        do {
            try await model.requestEmailCode(address)
            sent += 1
            code = ""
            step = .code
            focus = .code
        } catch {
            problem = error.localizedDescription
        }
    }

    private func verify() async {
        guard let address = cleanEmail, EmailCodeRules.cleanCode(code) != nil, !isWorking else { return }
        isWorking = true
        problem = nil
        defer { isWorking = false }
        do {
            try await model.signInWithEmailCode(email: address, code: code)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}
