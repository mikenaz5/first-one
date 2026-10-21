# Slate iOS app

SwiftUI app for creators (photographers, videographers) to get booked with a contract in every booking. Spec: `../SPEC.md`. Setup and backend notes: `README.md`.

## Commands

- `xcodegen generate` regenerates `Slate.xcodeproj` from `project.yml`. Never edit the `.xcodeproj` and never commit it. Add new Swift files by dropping them in `Slate/` or `SlateTests/`; XcodeGen picks them up.
- Test: `xcodebuild test -project Slate.xcodeproj -scheme Slate -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO`
- CI (`.github/workflows/ios.yml`) does the same on macOS. If you can't run Xcode (for example on Linux), CI is the compile check.

## Design rules (from the product owner; they apply to every screen)

- Swift and SwiftUI, iOS/iPadOS first, following Apple's HIG. Min iOS 17. Gate newer APIs with `#available`, and wrap iOS 18+ API in `#if compiler(>=6.0)`.
- Use system fonts via semantic text styles (never fixed sizes), SF Symbols, and system colors, so Light/Dark and Dynamic Type work. Colors, spacing, radii, type and card styles come from `DesignSystem/DesignSystem.swift`. Don't hardcode literals.
- Native patterns: `NavigationStack` per tab, `TabView` (Home, Bookings, Services, Messages, Profile), sheets with detents, swipe actions, `.refreshable`, context menus. Don't paint custom bar backgrounds; let the system draw bars.
- Generous whitespace, rounded continuous corners, subtle materials, spring animations (`Animation.slateSpring` etc.), haptics via `.sensoryFeedback` on key actions. Respect Reduce Motion (`motionSafe`).
- Accessibility first: VoiceOver labels on icon-only controls, 44pt minimum tap targets (`Metrics.minTapTarget`), contrast, and decorative images hidden from VoiceOver.
- Booking a service takes 3 taps or fewer (defined precisely in SPEC.md).

## Architecture

- `AppModel` (`@Observable`, `@MainActor`) is the single source of account state. Views read it from the environment.
- All server access goes through the `SlateBackend` protocol. `LocalBackend` (on-device, default, used by tests) and `SupabaseBackend` implement it. New features add methods to the protocol and both implementations; keep the local one working so the app runs with no setup.
- Pure logic (rules, validation, completeness) lives in `Core/` with no UI imports so it stays easy to test.
- Swift language mode is 5; don't enable strict concurrency or Swift 6 mode without a deliberate migration.

## Conventions

- Add unit tests for any logic you add in `Core/` or `ProfileDraft`. UI is verified by building and running, not unit tests.
- Keep `HandleRules` and the `creator_profiles.handle` SQL check in sync, and likewise the portfolio limit (12) in `AppConfig` and the SQL trigger.
- Storage paths use lowercase UUIDs, because Postgres compares `auth.uid()::text` case-sensitively.
- Secrets live in `Config/Secrets.xcconfig` (git-ignored). Only the Supabase anon key belongs in the app, never the service-role key.
