# Slate (working title): iOS app

SwiftUI app for photographers, videographers and freelance creators to get booked with a contract built into every booking. Product details are in [`../SPEC.md`](../SPEC.md).

**What exists today:**

- The project scaffold, design system and five-tab shell.
- Creator onboarding and profiles: Sign in with Apple, profile photo, bio, specialties, location, a photo and reel portfolio.
- **Service builder:** creators make packages (price, duration, deliverables, turnaround, deposit, optional add-ons such as extra hours, drone footage and rush delivery). Clients see them as cards.
- **Availability and booking:** working hours, blackout dates, booking rules, Apple Calendar sync via EventKit, and a client booking sheet with add-ons, date and time, and a price summary. Double-booking is prevented.
- A basic Bookings tab (upcoming and past, detail, cancel).

Messages, contracts and payments are not built yet. A booking today reserves the time; nothing is signed or charged.

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

## Packages, availability and booking

**Packages** are plain values (`ServicePackage`, `AddOn`) validated by `PackageRules`, which is the one list of limits the form, both backends and the SQL agree on. Prices are whole cents. The deposit is a fixed amount set per package; add-ons are settled in the balance. An "extra time" add-on lengthens the booking (so it blocks more of the calendar) and a "rush" add-on shortens delivery (never below one day).

**Finding open times** is a pure function, `AvailabilityEngine`, over the creator's working hours, blackout dates, minimum notice, how far ahead people can book, the gap after each booking, and blocked time ranges. It runs in the creator's time zone, so a client in another zone sees exactly when the shoot is. It handles daylight-saving gaps (the missing 2:00 AM on spring-forward day is not offered twice). The booking sheet preselects the earliest opening, so the usual path is: tap a package, tap Book.

**No double booking** is enforced in the data layer, not only on the screen:

| Backend | How |
|---|---|
| Postgres (`supabase/migrations/…packages_availability_bookings.sql`) | An exclusion constraint forbids two active bookings for one creator with overlapping time ranges (`[start, end + buffer)`), so it holds even if two clients tap Book at the same instant. Clients can't write `bookings` directly: they call `create_booking()`, which re-checks hours, blackouts, notice, grid, the creator's busy time and the add-ons, and **computes the price itself** from the creator's package. |
| On-device (`LocalBackend`) | It is an actor, so the check-then-save runs as one step. It re-checks with the same `AvailabilityEngine` the screen used, so what the screen offers is what is accepted. |

If someone else takes the time first, the sheet says so, refreshes, and preselects the next opening.

**Apple Calendar** (`CalendarService`, `AppModel+Calendar`, the Availability sheet):
- *Block times I'm busy* reads the chosen calendars and uploads **only merged start and end times**, never titles, places or guests. It skips cancelled events, events marked free, declined invitations, all-day events (unless switched on) and Slate's own booking events. Busy time is only as fresh as the creator's last sync (when they open the app or edit their calendar), so it is a convenience, not a guarantee.
- *Add bookings to my calendar* writes confirmed bookings as events with reminders. Clients are only ever asked for write-only access, the lightest permission.
- Calendar settings are stored on the device, because calendar identifiers only mean something there.

**Trying the client side alone.** On-device mode lets you book your own packages (a server-backed account can't). Use *Profile → Preview as a client*, or *Home → Open as a client*, or open `slate://book/<your-handle>`. Bookings made this way are labelled "Test booking".

## Contracts

Every booking carries a contract that both people sign before the booking exists.

- **Templates.** A creator keeps up to 20 contracts (`ContractTemplate`): a title and ordered sections written with `{{placeholders}}`. There are 17 fields (client and creator name, package, shoot date, time, time zone, duration, deliverables, add-ons, price, deposit, balance, turnaround, delivery date, cancellation policy, usage rights, client notes). The list is closed: the editor's Insert field menu, `ContractRules`, the SQL trigger and the renderer all use the same one, and a contract can't be saved with an unknown field or without the six essentials (who, what, when, how much, cancellation). Wording changes bump a version; signed contracts keep the version they were signed on.
- **Starters.** Photography, videography and general freelance contracts (`StarterTemplates`), plus a blank one. They are plain-language starting points, not legal advice, and the app says so wherever they're offered.
- **Each package picks** a contract, a cancellation policy (flexible, moderate or strict) and usage rights. A package can't be shown to clients without a contract. The policy and rights texts are fixed wording that goes into `{{cancellation_policy}}` and `{{usage_rights}}`.
- **Book and sign in one step.** The booking sheet ends in *Review & sign*: the contract as the **backend** filled it in (`preview_contract` in SQL, the same `ContractRenderer` on-device), a clean readable view, and a typed or drawn signature with a consent line. The client signs the SHA-256 of the exact text they were shown. `create_booking` re-renders the contract itself and refuses with `contract_changed` if the words moved in the meantime, in which case the sheet shows the new version and asks again. The booking and its contract are written in one database call, so there's never one without the other.
- **The creator's signature** is saved once (typed or drawn) with a standing authorization, and applied to each contract automatically at booking. It is recorded as *on file*, not as if they had signed that moment. This is a deliberate choice: it keeps booking at a few taps and never leaves a client waiting. A creator who wants to approve each job by hand is not supported yet. Without a saved signature, clients can't book (`creator_not_ready`), and the Services tab tells the creator why.
- **Filling in is safe.** Client names and notes are cleaned so they can't contain a placeholder (`{{` becomes `{ {`), placeholders are replaced in a single pass, and values come from the creator's package, never from the request.
- **Same words everywhere.** Money, dates and times are formatted without the device's locale, so a contract reads the same on every phone and on the server. `SlateTests/Fixtures/contract_golden.json` holds contracts rendered from the same inputs; the Postgres tests and the Swift tests both check they produce exactly those words (including a night shoot across a daylight-saving change and hostile names). To add a case, run the Postgres tests with `PRINT_GOLDEN=1`, read the output carefully, and paste it in as `expected_text`.
- **Signed PDF.** Real text across as many pages as needed, then a page with both signatures and a certificate (who, how, when in UTC, document IDs, and the hash). It is stored once at `contracts/<contract id>.pdf` in a private bucket that only the two people on the contract can read, and the first PDF stored wins, so both see the identical file. Either person's app creates it if it isn't there yet. *The PDF is made on the phone, so treat the stored contract text and its hash as the record and the PDF as a convenient copy of it.* Producing it on the server is the stronger design and a good next step.
- **What e-signatures are worth** depends on where you work. The app records name, method, time, consent wording version, device and a best-effort IP address, but have a lawyer confirm this suits your jurisdiction before relying on it.

## Layout

```
ios/
  project.yml                 XcodeGen project definition (source of truth)
  Config/                     xcconfig, entitlements (Info.plist is generated)
  Slate/
    App/                      Entry point, root state (AppModel), tabs
    Core/                     Models, rules, AvailabilityEngine, backend protocol + Local and Supabase backends, media
    Services/                 EventKit (CalendarService), signed-PDF rendering (ContractPDF)
    DesignSystem/             Tokens, card styles, motion, shared components
    Features/                 Auth, Onboarding, Profile, Home, Services, Availability, Booking, Bookings, Contracts
    Resources/                Asset catalog (accent color, app icon)
  SlateTests/                 Unit tests (rules, engine, pricing, drafts, LocalBackend, booking flow, contracts, PDF)
    Fixtures/contract_golden.json   Contract text both SQL and Swift must reproduce exactly
  supabase/                   SQL migrations, Postgres rule tests, delete-account Edge Function
```

The design system is `Slate/DesignSystem/DesignSystem.swift` (spacing, radii, colors, type scale, card styles, motion) plus `Components.swift`. Everything is built from system fonts, system colors and SF Symbols, so Dark Mode, Dynamic Type and OS-level visual updates apply automatically.

## Status of verification

Written on a Linux machine with no Xcode, so **the Swift is compiled and tested by CI, not locally.** The `iOS` workflow builds the app and runs the unit tests on a macOS runner; treat it as the source of truth.

The booking rules in SQL are tested for real: `supabase/tests/booking_rules.py` applies the migrations to a throwaway Postgres and tries to break them (overlaps, buffers, hours, blackouts, notice, price tampering, row level security, contract rendering and placeholder injection, signature rules, signed-PDF storage access, and 30 clients racing for one slot). The `Database` workflow runs it on every change to `supabase/`; you can run it locally with `PGPORT=5432 python3 supabase/tests/booking_rules.py`.

**Never exercised** (needs a device, an Apple ID or a live project): Sign in with Apple, Supabase auth, storage and the Swift calls to the booking and contract functions (including uploading and downloading the signed PDF), the Edge Function, EventKit permission prompts and event writing, the photo and video picking flows, and finger-drawing a signature on a real screen. The Swift side of the Supabase calls compiles but has not talked to a database.

## Known gaps

- **A booking doesn't collect a deposit yet.** The contract states the deposit and balance, but nothing is charged. Cancelling doesn't refund anything, even though the contract states the refund rules.
- **The creator can't approve bookings one by one**; their saved signature is applied automatically.
- **Signed PDFs are produced by the app, not the server** (see above).
- **Contracts can't be amended after signing**, and cancelling a booking doesn't mark its contract void.
- **No holds.** The spec's 10-minute slot hold isn't needed until payment exists; bookings are confirmed immediately.
- **Calendar busy time is device-synced**, so it can be stale, and events written with write-only access can't be removed again on cancel.
- **No push notifications or reminders** beyond the calendar alarms.
- **Booking links don't resolve.** `slate.example` is a reserved placeholder host. The Home tab says so.
- **Apple token revocation on account deletion** is not implemented (Apple requires it). It needs a client secret signed with your Apple key; see the TODO in `supabase/functions/delete-account/index.ts`.
- **The Apple user ID is kept in `UserDefaults`**, not the Keychain. It's an identifier, not a secret, but Keychain is the better home.
- **Profile photos are centre-cropped** to a circle. There's no crop/zoom UI yet.
- **English only**; strings aren't localized yet.
- **Portfolio uploads are sequential and unretried.** A failed upload during onboarding shows an alert and the person finishes from their profile.
