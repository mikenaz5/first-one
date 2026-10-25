import Foundation

/// Client accounts on the on-device backend: signing in with an emailed code, and remembering a person's name.
extension LocalBackend {
    /// What is kept about a person who has no profile: the name that goes on the contracts they sign.
    struct StoredClient: Codable {
        var name: String?
        var email: String?
    }

    func clientURL(_ userID: UUID) -> URL {
        userDirectory(userID).appendingPathComponent("client.json")
    }

    func storedClient(_ userID: UUID) -> StoredClient? {
        read(StoredClient.self, from: clientURL(userID))
    }

    func rememberClient(_ userID: UUID, name: String?, email: String?) throws {
        try write(StoredClient(name: name, email: email), to: clientURL(userID))
    }

    // MARK: Auth

    /// On a device with no server nothing is sent: the screen shows the demo code instead.
    func requestEmailCode(_ email: String) async throws {
        guard EmailCodeRules.cleanEmail(email) != nil else { throw SlateError.invalidEmail }
    }

    func signInWithEmailCode(email: String, code: String) async throws -> AuthSession {
        guard let address = EmailCodeRules.cleanEmail(email) else { throw SlateError.invalidEmail }
        guard let digits = EmailCodeRules.cleanCode(code), digits == EmailCodeRules.demoCode else { throw SlateError.invalidCode }

        // The same address is always the same person, so a repeat client gets their bookings back.
        var accounts = read([String: UUID].self, from: accountsURL) ?? [:]
        let key = "email:\(address)"
        let userID = accounts[key] ?? UUID()
        accounts[key] = userID
        try write(accounts, to: accountsURL)

        let session = AuthSession(userID: userID, appleUserID: nil, email: address, fullName: storedClient(userID)?.name)
        try write(session, to: sessionURL)
        return session
    }

    func updateDisplayName(_ name: String) async throws -> AuthSession {
        guard var session = read(AuthSession.self, from: sessionURL) else { throw SlateError.notSignedIn }
        guard let clean = EmailCodeRules.cleanName(name) else { throw SlateError.nameRequired }
        session.fullName = clean
        try write(session, to: sessionURL)
        try rememberClient(session.userID, name: clean, email: session.email)
        return session
    }
}
