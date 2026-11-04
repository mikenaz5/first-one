#if DEBUG
import SwiftUI

/// Debug builds only: sign in with an email and password for a person made by hand in the Supabase dashboard
/// (Authentication, Users, Add user), so the real server can be tried before email codes or Sign in with Apple are
/// set up. Release builds don't contain this, and the product never has passwords.
struct TestPasswordSignInView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("you@example.com", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .frame(minHeight: Metrics.minTapTarget)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .frame(minHeight: Metrics.minTapTarget)
                    if let problem {
                        Text(problem).font(.footnote).foregroundStyle(Color.slateDanger)
                    }
                    Button {
                        Task { await signIn() }
                    } label: {
                        HStack {
                            Text("Sign in")
                            if isWorking { Spacer(); ProgressView() }
                        }
                        .frame(minHeight: Metrics.minTapTarget)
                    }
                    .disabled(isWorking || email.isEmpty || password.isEmpty)
                } footer: {
                    Text("For testing only, in builds made from the source code. Make the person in your Supabase project under Authentication, Users, Add user (tick Auto Confirm User). A release of Slate Pro has no passwords: people sign in with Apple or an emailed code.")
                }
                    .listRowBackground(Color.slateCard)
            }
            .scrollContentBackground(.hidden)
            .slatePageBackground()
            .navigationTitle("Test sign-in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .interactiveDismissDisabled(isWorking)
    }

    private func signIn() async {
        isWorking = true
        problem = nil
        defer { isWorking = false }
        do {
            try await model.signInWithTestPassword(email: email, password: password)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}
#endif
