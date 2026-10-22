import CryptoKit
import Foundation

enum Hashing {
    /// Lowercase hex SHA-256 of the UTF-8 bytes of `text`. Matches `encode(digest(text, 'sha256'), 'hex')` in Postgres.
    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
