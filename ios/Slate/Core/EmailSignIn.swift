import Foundation

/// Signing in with an emailed code: the free "guest" account, and the way back in for a repeat client. There is no
/// password. The same address always signs in to the same account.
enum EmailCodeRules {
    static let codeLength = 6
    /// How long a code works, in minutes. The server decides this; the screen only says it.
    static let lifetimeMinutes = 10
    /// What every code is on a device with no server, so the whole flow can be tried.
    static let demoCode = "123456"
    static let nameMaxLength = 80

    /// The address trimmed and in lower case, or nil when it can't be an email address.
    static func cleanEmail(_ raw: String) -> String? {
        let email = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !email.isEmpty, email.count <= 254, !email.contains(where: \.isWhitespace) else { return nil }
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, let local = parts.first, let domain = parts.last, !local.isEmpty, local.count <= 64 else { return nil }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }), let last = labels.last, last.count >= 2 else { return nil }
        return email
    }

    /// The six digits, however they were typed or pasted ("123 456", "123-456"); nil otherwise.
    static func cleanCode(_ raw: String) -> String? {
        let digits = raw.filter { $0.isASCII && $0.isNumber }
        let others = raw.filter { !($0.isASCII && $0.isNumber) && !$0.isWhitespace && $0 != "-" }
        return digits.count == codeLength && others.isEmpty ? digits : nil
    }

    /// The name that goes on contracts: words separated by single spaces, 1 to 80 characters; nil if empty or too long.
    static func cleanName(_ raw: String) -> String? {
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty, collapsed.count <= nameMaxLength else { return nil }
        return collapsed
    }
}
