import XCTest
@testable import Slate

#if DEBUG
/// The debug-only password sign-in exists for a real server, never for the on-device backend.
final class TestSignInTests: XCTestCase {
    func testPasswordSignInIsRefusedOnTheDevice() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("slate-signin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = ManualClock(Date())
        let backend = LocalBackend(root: root, clock: { clock.now })
        do {
            _ = try await backend.signInWithPassword(email: "a@example.com", password: "secret")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error is SlateError)
        }
        let restored = await backend.restoreSession()
        XCTAssertNil(restored, "nobody was signed in by the attempt")
    }
}
#endif
