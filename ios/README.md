# Slate (working title): iOS app

SwiftUI app for photographers, videographers and freelance creators to get booked with a contract built into every booking. Product details are in [`../SPEC.md`](../SPEC.md).

**What exists today:** the project scaffold, the design system, the five-tab shell, and creator onboarding and profiles (Sign in with Apple, profile photo, bio, specialties, location, a photo and reel portfolio). Bookings, Services and Messages are labelled placeholders. Booking, contracts and payments are not built yet.

## Backend recommendation: Supabase, with Stripe Connect for money

| | **Supabase** (recommended) | **Firebase** | **Custom server** |
|---|---|---|---|
| Data model | Postgres. Relations, constraints and transactions. | Firestore (documents). Joins and cross-document rules are manual. | Anything. |
| Fit for this product | Strong. Double-booking can be prevented with an exclusion constraint on time ranges. An append-only audit log, immutable contract rows and financial reporting are plain SQL. | Weaker. Atomic "hold a slot, then confirm after signature and payment" and audit/reporting need extra work. | Strong, but you build and run everything. |
| Auth | Sign in with Apple via native ID token | Sign in with Apple | You build it |
| Files | Storage with per-folder security policies, signed URLs | Cloud Storage | S3 or similar |
| Server logic | Edge Functions (TypeScript/Deno) for Stripe, webhooks, PDF generation | Cloud Functions | Whatever you run |
| Offline and realtime | Realtime channels. Offline caching is DIY. | Best in class | DIY |
| Swift SDK | Good, younger | Mature | n/a |
| Lock-in and cost | Open source, self-hostable, SQL migrations live in this repo. Predictable pricing. | Proprietary. Per-read pricing is hard to forecast. | Highest ops cost |

**Payments are separate from either choice.** Neither Supabase nor Firebase processes payments. The plan from the spec is Apple Pay → Stripe → Stripe Connect payouts to creators, with the secret-key work in Edge Functions. Nothing in this repo touches money yet.

**Why not Firebase?** Its SDKs are better, and its offline support is genuinely better. But this product's core promises ("a booking is confirmed only when the contract is signed *and* the deposit is paid", "nobody can double-book a creator", "the audit trail can't be edited") are relational and transactional, and that's where Postgres is simply the easier tool.

**Trade-off you accept with Supabase:** the Swift SDK is younger, there's no built-in offline cache, and you'll write a little server code (TypeScript Edge Functions) for Stripe and PDFs.

## Running it

Requirements: Xcode 16 or newer, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
cd ios
xcodegen generate     # creates Slate.xcodeproj from project.yml (the project file is not committed)
open Slate.xcodeproj
```

Run on a simulator. With no backend configured the app uses **`LocalBackend`**: accounts, profile and media live in the app's Application Support folder, so everything works offline with no setup. In Debug builds, the welcome screen shows **Continue with a demo account** so you can skip Apple's sheet. Real Sign in with Apple also works on a simulator that is signed into an Apple ID, once you set a development team (below).

Tests: `⌘U`, or

```sh
xcodebuild test -project Slate.xcodeproj -scheme Slate \
  -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO
```

### Using a real Supabase project

1. Create a project. Install the [Supabase CLI](https://supabase.com/docs/guides/cli), then from `ios/`:
   ```sh
   supabase init            # creates supabase/config.toml; keep the existing migrations folder
   supabase link --project-ref <ref>
   supabase db push         # applies supabase/migrations/*.sql
   supabase functions deploy delete-account
   ```
2. In the dashboard: **Authentication → Providers → Apple**, enable it and add this app's bundle ID (`com.example.slate`) to the authorized client IDs.
3. `cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig` and fill in the project URL, the **anon** key and your Apple team ID. Never put the `service_role` key in the app.
4. Regenerate and run. The app switches to `SupabaseBackend` whenever both values are set.

### Signing and capabilities

Set `DEVELOPMENT_TEAM` in `Config/Secrets.xcconfig`. The app currently uses one capability, Sign in with Apple (`Config/Slate.entitlements`). Apple's free "Personal Team" doesn't support it; use a paid developer account. Change the bundle ID (`com.example.slate` in `project.yml`) before shipping.

## Layout

```
ios/
  project.yml                 XcodeGen project definition (source of truth)
  Config/                     xcconfig, entitlements (Info.plist is generated)
  Slate/
    App/                      Entry point, root state (AppModel), tabs
    Core/                     Models, rules, backend protocol + Local and Supabase backends, media processing
    DesignSystem/             Tokens, card styles, motion, shared components
    Features/                 Auth, Onboarding, Profile, Home
    Resources/                Asset catalog (accent color, app icon)
  SlateTests/                 Unit tests (rules, models, draft logic, LocalBackend)
  supabase/                   SQL migration + delete-account Edge Function
```

The design system is `Slate/DesignSystem/DesignSystem.swift` (spacing, radii, colors, type scale, card styles, motion) plus `Components.swift`. Everything is built from system fonts, system colors and SF Symbols, so Dark Mode, Dynamic Type and OS-level visual updates apply automatically.

## Status of verification

Written on a Linux machine with no Xcode. Before this was pushed, the Swift files were syntax-checked with tree-sitter and the SQL was parsed with Postgres's own parser, but **nothing was compiled or run locally.** The `iOS` GitHub Actions workflow builds the app and runs the unit tests on a macOS runner; treat that as the source of truth. Still never exercised on a real device or against a live Supabase project: Sign in with Apple, Supabase auth and storage, the Edge Function, and the photo and video picking flows.

## Known gaps

- **Booking links don't resolve.** `slate.example` is a reserved placeholder host. The Home tab says so.
- **Apple token revocation on account deletion** is not implemented (Apple requires it). It needs a client secret signed with your Apple key; see the TODO in `supabase/functions/delete-account/index.ts`.
- **The Apple user ID is kept in `UserDefaults`**, not the Keychain. It's an identifier, not a secret, but Keychain is the better home.
- **Profile photos are centre-cropped** to a circle. There's no crop/zoom UI yet.
- **English only**; strings aren't localized yet.
- **Portfolio uploads are sequential and unretried.** A failed upload during onboarding shows an alert and the person finishes from their profile.
