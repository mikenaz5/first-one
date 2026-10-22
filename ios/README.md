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

Set `DEVELOPMENT_TEAM` in `Config/Secrets.xcconfig`. The default build uses one capability, Sign in with Apple (`Config/Slate.entitlements`); Apple Pay and push notifications are switched on through `Config/Secrets.xcconfig` (see "Turning on real payments" and "Turning on notifications"). Apple's free "Personal Team" doesn't support any of them; use a paid developer account. Change the bundle ID (`com.example.slate` in `project.yml`) before shipping.

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

## Payments

The deposit is paid when the client signs, the balance after the work is delivered, and cancelling refunds by the policy the client agreed to.

| Step | What happens |
|---|---|
| **Sign & pay** | The client signs the contract. If the package has a deposit, the booking is **held for 15 minutes** (its time is blocked, its contract is *pending* and carries only the client's signature) and Apple Pay opens for the deposit. |
| **Deposit paid** | Stripe tells our webhook the money arrived. Only then does the booking become **confirmed**, the creator's saved signature is added and the contract becomes **executed**. A package with no deposit is confirmed and executed immediately. |
| **Hold runs out** | The time is released, the pending contract is voided and the unpaid payment cancelled. Nothing was charged. If the money arrives just *after* the hold ended and the time is still free, the booking is confirmed anyway; if someone else has the time by then, the payment is refunded in full automatically. |
| **Delivery** | After the shoot starts, the creator taps **Mark as delivered**. That makes the balance (total minus deposit) payable, and the client sees **Pay balance**. Paying it completes the booking. If the deposit already covered everything, delivery completes it. |
| **Cancel** | The sheet shows **the exact refund before the final tap**. The client gets the share of what they paid that the package's policy gives for how far ahead they cancel (Flexible: all back from 24 hours out, else half. Moderate: all from 7 days, half from 48 hours, else none. Strict: half from 14 days, else none). If the **creator** cancels, the client always gets everything back. The refund is rounded down to the cent and returns to the card that paid. |

Every booking shows its money in plain words (*Deposit due*, *Deposit paid*, *Balance due*, *Paid in full*, *Refund on the way*, *Refunded $250*…) in the list and on its detail screen, with the full payment history under it.

**How it is built so a client can't fake a payment.** The app never decides an amount and never says "this was paid". The database computes what is owed from the booking (`payment_prepare`), Edge Functions create the Stripe PaymentIntent for exactly that amount, and the booking changes only when **Stripe's signed webhook** reports success (`payment_record_success`, which also refuses a payment whose amount doesn't match). Refunds work the other way round: cancelling records what is owed in the same database transaction (`cancel_booking`), and `process-refunds` then sends it to Stripe; if that call fails the refund simply stays owed and is retried (on the next app launch, refresh, or call), so a cancellation can never lose a refund.

**Stripe Connect.** Creators connect a Stripe **Express** account from the Services tab (Stripe's own pages collect identity and bank details; Slate never sees them). Payments are **destination charges**: the money goes to the creator's account, with an optional platform fee (`PLATFORM_FEE_BPS`, default **0**, so Slate takes nothing). A creator whose account can't take charges yet can't take bookings that need a deposit, and the client is told before they sign. Stripe keeps its normal processing fee on refunds; the creator bears that, as with any refund through Stripe.

**On-device mode is pretend.** With no server configured, "Pay" is instant and clearly labelled *Demo mode: no card is charged*, so the whole flow can be tried with no setup. It follows the same rules as the server (the same tests describe both), but no money exists.

### Turning on real payments

1. **Stripe:** create an account, enable Connect (Express), and note the secret key (`sk_…`) and publishable key (`pk_…`).
2. **Database and functions**, from `ios/`:
   ```sh
   supabase db push
   supabase secrets set STRIPE_SECRET_KEY=sk_test_… STRIPE_WEBHOOK_SECRET=whsec_… # PLATFORM_FEE_BPS=0 by default
   supabase functions deploy create-payment-intent process-refunds connect-onboarding
   supabase functions deploy stripe-webhook connect-redirect --no-verify-jwt
   ```
3. **Webhook:** in the Stripe dashboard add `https://<project>.supabase.co/functions/v1/stripe-webhook` for `payment_intent.succeeded`, `payment_intent.payment_failed`, `refund.created`, `refund.updated`, `refund.failed`, `charge.refund.updated` and `account.updated`, and copy its signing secret into `STRIPE_WEBHOOK_SECRET`.
4. **Apple Pay:** register a merchant ID in your Apple developer account and its payment-processing certificate in the Stripe dashboard. In `Config/Secrets.xcconfig` set `STRIPE_PUBLISHABLE_KEY`, `APPLE_PAY_MERCHANT_ID` and `CODE_SIGN_ENTITLEMENTS = Config/Slate.ApplePay.entitlements` (see `Secrets.example.xcconfig`). Without these, a server-backed build tells the person that payments aren't set up rather than failing mysteriously, and on-device mode is unaffected.

## Messaging and notifications

**Messages.** Every booking has one conversation between its two people (Messages tab, or "Message …" on a booking). Besides what people write, the conversation records what happens to the booking, as short centred lines: *booked*, *deposit paid*, *contract signed*, *delivered*, *balance paid*, *cancelled (and what's refunded)*. Those lines are written by the database from the booking's own changes (triggers on `bookings`, `payments` and `contracts`), never by a person, so they can be trusted as a history. A text message is tidied before it is stored (line breaks, control characters; `MessageRules` and `message_clean()` share a fixture), limited to 2,000 characters and to 20 a minute, and sent with an id the app makes so a retry after a dropped connection can't post it twice. People who aren't in the booking can read and write nothing (Row Level Security plus the functions). A lapsed hold has no conversation; a cancelled or completed booking keeps its conversation, for refund questions. New lines arrive by **polling every few seconds while a conversation is open** (and every ten on the list), not a live connection.

**Notifications.** Seven kinds, grouped into five switches in *Profile → More → Notifications*: **bookings** (a new booking, a cancellation), **contracts** (signed by both), **payments** (a deposit or balance received; a balance falling due), **messages**, and **shoot reminders** (a day before and two hours before, for both people, for confirmed bookings only). The payment and contract notifications are sent when Stripe confirms the money, not when someone taps, and nothing is announced for a payment that was handed straight back (cancelled while paying, or a duplicate). The app asks for permission only when the person taps *Turn On* (a card on Home, or the settings screen), never at launch. Tapping a notification opens the booking or the conversation (`slate://booking/<id>`, `slate://messages/<id>`). The icon badge is the number of unread messages.

**Two ways reminders arrive, never both.** With a server, the database queues reminders and `send-push` delivers them; they are correct even if the other person cancelled while your phone was off, and they follow you across devices. On-device (no server), the app schedules them itself as local notifications from its bookings and keeps them in step whenever a booking changes (50 at most, soonest first). The reminder rules are the same in both (`enqueue_due_reminders()` and `ReminderPlanner`; the lead times are in `SlateTests/Fixtures/notification_rules.json`, checked by both test suites).

**How a push gets from an event to a phone.** Triggers write *facts* (who, what, which booking, the amounts) into `push_outbox`, with a dedupe key so the same event can't queue twice and with the person's settings applied. The `send-push` Edge Function claims what's due (the database hands each notification to one run at a time), words each one, signs a request to Apple's push service with your `.p8` key, and tells the database how it went: delivered, try again (up to five times, with growing pauses), or *this device token is dead* (the app was deleted), in which case the token is forgotten. A phone that signs out unregisters itself. If a person has several devices, each gets it.

### Turning on notifications

Notifications on a server-backed build need Apple, Supabase and a schedule. None of it is needed to try messaging or reminders on-device.

1. **Apple:** in your developer account, turn on **Push Notifications** for the app's identifier, and create an **APNs Auth Key** (Keys → +, Apple Push Notifications service). Download the `.p8` file once and note its Key ID and your Team ID.
2. **App:** in `Config/Secrets.xcconfig` set `CODE_SIGN_ENTITLEMENTS` to `Config/Slate.Push.entitlements` (or `Config/Slate.ApplePay.Push.entitlements` with Apple Pay). Xcode builds talk to Apple's sandbox, TestFlight and App Store builds to production, and the app tells the server which (`PushEnvironment.current`).
3. **Functions**, from `ios/`:
   ```sh
   supabase db push
   supabase secrets set APNS_KEY_P8="$(cat AuthKey_XXXXXXXXXX.p8)" APNS_KEY_ID=XXXXXXXXXX APNS_TEAM_ID=YYYYYYYYYY APNS_TOPIC=com.example.slate PUSH_CRON_SECRET="$(openssl rand -hex 32)"
   supabase functions deploy send-push --no-verify-jwt
   ```
   `send-push` is for the scheduler, not for people: it answers only a request carrying the service role key or `PUSH_CRON_SECRET`, and answers `503` (touching nothing) until the four `APNS_*` values are set.
4. **Schedule it.** Run `send-push` every minute, which both sends what's waiting and queues the reminders that have come due. With the `pg_cron` and `pg_net` extensions enabled (Database → Extensions) and the secret stored in Vault, for example:
   ```sql
   select cron.schedule('slate-send-push', '* * * * *', $$
     select net.http_post(
       url := 'https://<project>.supabase.co/functions/v1/send-push',
       headers := jsonb_build_object('Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'push_cron_secret')),
       body := '{}'::jsonb);
   $$);
   ```
   For messages to arrive in seconds rather than within a minute, also add a **Database Webhook** on inserts into `push_outbox` that calls the same function (Database → Webhooks). Without a schedule nothing is ever sent: that is the one step that is easy to miss.

Until then the app still builds and runs. Notification settings explain that this build can't receive push, and (on-device) reminders still work.

**Never exercised:** a real push to a real phone. The wording, the payload, the APNs token signing (checked against its public key), the request shape, the retry and dead-token rules and the access check on `send-push` are tested in Node; the queue, the triggers, the reminder windows and the access rules are tested in Postgres; the permission flow, reminder scheduling, registration and the conversation screens' logic are tested in Swift against a stand-in for the system's notification center. Not exercised: HTTP/2 to `api.push.apple.com`, a device token, the entitlement, the notification banner, `pg_cron`/`pg_net`, or the Deno wiring.

## Layout

```
ios/
  project.yml                 XcodeGen project definition (source of truth)
  Config/                     xcconfig, entitlements (Info.plist is generated)
  Slate/
    App/                      Entry point, root state (AppModel), tabs
    Core/                     Models, rules, AvailabilityEngine, backend protocol + Local and Supabase backends, media
    Services/                 EventKit (CalendarService), signed-PDF rendering (ContractPDF), Apple Pay (PaymentAuthorizer), notifications (NotificationService)
    DesignSystem/             Tokens, card styles, motion, shared components
    Features/                 Auth, Onboarding, Profile, Home, Services, Availability, Booking, Bookings, Contracts, Payments, Messages, Notifications
    Resources/                Asset catalog (accent color, app icon)
  SlateTests/                 Unit tests (rules, engine, pricing, drafts, LocalBackend, booking flow, contracts, PDF, payments)
    Fixtures/contract_golden.json   Contract text both SQL and Swift must reproduce exactly
    Fixtures/refund_golden.json     Refund amounts both SQL and Swift must agree on
    Fixtures/notification_rules.json  Message tidying, the message limit and reminder times both must agree on
  supabase/
    migrations/               Schema, security and the booking, contract and payment functions
    tests/                    Postgres rule tests (booking_rules.py)
    functions/                Edge Functions: delete-account, the payment ones (logic in _shared/payments.ts) and send-push (_shared/push.ts, apns.ts)
    function-tests/           Node tests and type-check for the payment and push logic
```

The design system is `Slate/DesignSystem/DesignSystem.swift` (spacing, radii, colors, type scale, card styles, motion) plus `Components.swift`. Everything is built from system fonts, system colors and SF Symbols, so Dark Mode, Dynamic Type and OS-level visual updates apply automatically.

## Status of verification

Written on a Linux machine with no Xcode, so **the Swift is compiled and tested by CI, not locally.** The `iOS` workflow builds the app and runs the unit tests on a macOS runner; treat it as the source of truth. With messaging and notifications it compiled and ran 412 tests with 0 failures on a macOS runner, including the check that Swift renders the golden contracts word for word as Postgres does, quotes the golden refunds to the cent, and tidies messages and picks reminder times from the same fixture the database is tested against. The new tests cover the message rules, the reminder planner, conversations and settings on the on-device backend, and the permission, registration and reminder flows against a stand-in for the system's notification center. (CI caught a real bug on the way: reminders waiting for a permission answer weren't cleared when the answer was no.)

The booking rules in SQL are tested for real: `supabase/tests/booking_rules.py` applies the migrations to a throwaway Postgres and tries to break them (overlaps, buffers, hours, blackouts, notice, price tampering, row level security, contract rendering and placeholder injection, signature rules, signed-PDF storage access, holds and their expiry, deposits, late and duplicate payments, balances, refunds by every policy, who may call which payment function, who can read or write a conversation, message limits and retries, unread counts, the lines and notifications each booking event produces (and none for a payment that was handed straight back), reminder windows, the push queue's claiming, retrying and clean-up, device tokens, and many clients racing for one slot, one payment report or one message). It once caught a real bug: two clients booking overlapping times at the same instant could get a deadlock error instead of "slot taken". Bookings for one creator are now serialised with an advisory lock, and the race tests passed ten runs in a row afterwards. The `Database` workflow runs it on every change to `supabase/`; you can run it locally with `PGPORT=5432 python3 supabase/tests/booking_rules.py`.

The payment and push logic in the Edge Functions (`_shared/payments.ts`, `push.ts`, `apns.ts`) is type-checked and tested with Node against fake database, Stripe and APNs objects (`cd supabase/function-tests && npm ci && npm test`): amounts and destinations come from the database, a forged or repeated webhook changes nothing, refunds are idempotent and retry only when Stripe couldn't be reached; notifications are worded as expected in the shoot's own time zone, the APNs token verifies against its public key and is reused for half an hour, dead device tokens are forgotten, failures are retried, and `send-push` refuses anyone without the service key. CI runs it too.

**Never exercised** (needs a device, an Apple ID, Stripe, Apple's push servers or a live project): Sign in with Apple, Supabase auth, storage and the Swift calls to the booking, contract, payment and messaging functions (including the signed PDF upload), **a real push notification reaching a real phone (see "Turning on notifications")**, **Stripe itself (PaymentIntents, Connect onboarding, the webhook, refunds)**, **Apple Pay on a real device**, the thin Deno wiring that connects the tested payment and push logic to the real Stripe, APNs and Supabase clients (`_shared/runtime.ts` and each function's `index.ts`), EventKit permission prompts and event writing, the photo and video picking flows, and finger-drawing a signature on a real screen. The Swift side of the Supabase calls compiles but has not talked to a database.

## Known gaps

- **Payments have never run against Stripe or Apple Pay** (see above). Expect to fix small things the first time they do.
- **The creator can't approve bookings one by one**; their saved signature is applied automatically.
- **Signed PDFs are produced by the app, not the server** (see above).
- **Contracts can't be amended after signing.** Cancelling a booking voids its contract.
- **Little runs on a schedule you haven't set up.** Expired holds are released whenever anyone books, pays, messages or lists bookings, and owed refunds are retried when the app opens or refreshes; a scheduled job (for example `pg_cron` calling `expire_holds()` and `process-refunds`) would make both prompt even when nobody opens the app. Server-side push notifications and shoot reminders need the schedule in "Turning on notifications" and send nothing without it.
- **A balance is announced once, not chased.** The client gets one notification when the creator marks the work delivered; nothing repeats it, and a client who never pays isn't followed up or flagged as overdue.
- **No disputes, chargebacks, payout screens or earnings summary.** Stripe's dashboard has them.
- **Apple Pay's country comes from the device's region**, not the creator's. For creators outside that country it needs to come from their Stripe account.
- **Delivery is the creator's word.** There is no proof-of-delivery step and no client confirmation.
- **Calendar busy time is device-synced**, so it can be stale, and events written with write-only access can't be removed again on cancel.
- **Messages are fetched by polling**, every few seconds while a conversation is open, not streamed. There are no typing indicators, no read receipts shown to the other person, no photos or files, and a message can't be edited or deleted.
- **No way to report or block.** Messaging is limited to the two people on a booking, but Apple's App Review guideline 1.2 expects an app with user-generated content to offer reporting and blocking. Add them before submitting.
- **Notifications are English only, have no quiet hours or per-booking mute** (iOS Focus modes and the Show Previews setting apply), and a message's text appears in the banner. Nothing is retried for a phone that is off for more than the notification's lifetime (a day or two; a week for messages).
- **A person with no server-backed account gets only shoot reminders.** On-device, the other person is an account on the same phone, so there is nobody to send a push to.
- **Booking links don't resolve.** `slate.example` is a reserved placeholder host. The Home tab says so.
- **Apple token revocation on account deletion** is not implemented (Apple requires it). It needs a client secret signed with your Apple key; see the TODO in `supabase/functions/delete-account/index.ts`.
- **The Apple user ID is kept in `UserDefaults`**, not the Keychain. It's an identifier, not a secret, but Keychain is the better home.
- **Profile photos are centre-cropped** to a circle. There's no crop/zoom UI yet.
- **English only**; strings aren't localized yet.
- **Portfolio uploads are sequential and unretried.** A failed upload during onboarding shows an alert and the person finishes from their profile.
