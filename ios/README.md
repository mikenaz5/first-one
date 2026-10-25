# Slate (working title): iOS app

SwiftUI app for photographers, videographers and freelance creators to get booked with a contract built into every booking. Product details are in [`../SPEC.md`](../SPEC.md).

## Run it on the simulator

You need a Mac with Xcode 16 or newer (it is built and tested with the latest Xcode). Nothing else: no Apple Developer account, no server, no keys.

Open Terminal (press ⌘ and Space, type Terminal, press Return), paste this one line and press Return:

```sh
curl -L -o slate.zip https://github.com/mikenaz5/first-one/archive/refs/heads/claude/ecstatic-curie-4456ah.zip && unzip -oq slate.zip && cd first-one-claude-ecstatic-curie-4456ah/ios && bash scripts/run-simulator.sh
```

(If you use git, `git clone -b claude/ecstatic-curie-4456ah https://github.com/mikenaz5/first-one.git`, then `cd first-one/ios` and `./scripts/run-simulator.sh` does the same.)

The script downloads XcodeGen (a small tool that makes the Xcode project; it uses Homebrew's copy if you have one), builds the app, starts an iPhone simulator, installs Slate and opens it. The first build downloads two Swift packages (Supabase and Stripe) and takes about ten minutes; later runs are much faster. On the welcome screen tap **Continue with a demo account**. From then on everything runs on the device: profile, services, booking and signing a contract, pretend payments, delivery and reviews, messages, and company accounts (*Invite ▸ Add pretend teammate* stands in for a second person). To see the client side, choose **I'm booking a creator**: with no server the app starts with eight made-up sample creators (profile, package, contract, hours, drawn pictures, reviews), so the featured grid on Home, search and booking all have someone to work with. The grid puts creators who work near the client first: tap the pin beside *Featured creators* (or the *See creators near you* card) and choose a city. The sample creators are in Austin, Chicago, Denver, Atlanta, Portland, Nashville, New York and Miami; *Use my location* needs the simulator's location set first (Features ▸ Location), so choosing a city is the easy way to try it.

To work in Xcode instead, run `./scripts/run-simulator.sh --xcode`. It generates `Slate.xcodeproj` and opens it; pick an iPhone simulator at the top and press Run. A simulator build needs no signing, so leave the Team empty. If Xcode still complains about signing, use the script, which always builds the simulator app unsigned.

If something goes wrong:

- *"Xcode isn't ready"*: open Xcode once and accept the license, or run `sudo xcode-select -s /Applications/Xcode.app`.
- *No iPhone simulator*: in Xcode open Settings ▸ Components and download the iOS Simulator.
- *The build fails*: the errors are printed and the whole log is in `ios/build/xcodebuild.log`. Send me the first error.
- *Packages won't download*: check the network, then in Xcode choose File ▸ Packages ▸ Reset Package Caches.
- *Start from a clean slate*: in the Simulator choose Device ▸ Erase All Content and Settings, or delete the app.
- *No demo button*: it appears in Debug builds only, and the script builds Debug.

To go beyond the demo (a real backend, real Sign in with Apple, payments, push), see "Using a real Supabase project" and the "Turning on…" sections below.

**What exists today:** Individual and company accounts with roles, billing and a team calendar; creator profiles and portfolios; packages, availability and booking with no double-booking; contracts signed inside the booking; Apple Pay deposits and balances through Stripe Connect, with refunds; messages and notifications; delivery by link, reviews, and a home screen widget; free client accounts (Sign in with Apple or an emailed code) that search for creators and explore a featured grid on Home; and a dark violet design. Most of it has been compiled and unit-tested by CI but has not yet been run against a live server or on a real phone (see "Status of verification" below).

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

The deposit is paid when the client signs, the balance once the client has confirmed they received the final files (see "Delivery and reviews"), and cancelling refunds by the policy the client agreed to.

| Step | What happens |
|---|---|
| **Sign & pay** | The client signs the contract. If the package has a deposit, the booking is **held for 15 minutes** (its time is blocked, its contract is *pending* and carries only the client's signature) and Apple Pay opens for the deposit. |
| **Deposit paid** | Stripe tells our webhook the money arrived. Only then does the booking become **confirmed**, the creator's saved signature is added and the contract becomes **executed**. A package with no deposit is confirmed and executed immediately. |
| **Hold runs out** | The time is released, the pending contract is voided and the unpaid payment cancelled. Nothing was charged. If the money arrives just *after* the hold ended and the time is still free, the booking is confirmed anyway; if someone else has the time by then, the payment is refunded in full automatically. |
| **Delivery** | After the shoot starts, the creator shares a link to the final files. When the client confirms they have them, the balance (total minus deposit) becomes payable and Apple Pay opens. Paying it completes the booking. If the deposit already covered everything, confirming completes it. Details below. |
| **Cancel** | The sheet shows **the exact refund before the final tap**. The client gets the share of what they paid that the package's policy gives for how far ahead they cancel (Flexible: all back from 24 hours out, else half. Moderate: all from 7 days, half from 48 hours, else none. Strict: half from 14 days, else none). If the **creator** cancels, the client always gets everything back. The refund is rounded down to the cent and returns to the card that paid. |

Every booking shows its money in plain words (*Deposit due*, *Deposit paid*, *Awaiting confirmation*, *Balance due*, *Paid in full*, *Refund on the way*, *Refunded $250*…) in the list and on its detail screen, with the full payment history under it.

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

## Delivery and reviews

After the shoot a booking has three more steps, each by one person and each recorded by the database.

| Step | Who | What happens |
|---|---|---|
| **Share the files** | Creator | Once the shoot has started, the booking shows **Share final files**. The creator pastes a link (Dropbox, Google Drive, WeTransfer, Frame.io… anything `https`) and an optional note (a password, an expiry date). They can **replace the link** until the client confirms, so a wrong one isn't a disaster; replacing it is announced as an update. The client is notified. Sharing asks for no money. |
| **Confirm receipt** | Client | The booking shows **Your files are ready** with **Open final files**, which shows the web address it goes to before it opens in the browser. After checking, the client taps **Confirm receipt**. If something is wrong, **Something's wrong** opens the conversation instead. Confirming twice changes nothing. |
| **Pay the balance** | Client | Confirming is what makes the balance payable (`payment_prepare` refuses it before then), and the app opens Apple Pay straight away. If the client closes the sheet, **Pay** is still on the booking. When nothing is owed (the deposit covered everything), confirming completes the booking. |
| **Review** | Client | Once the booking is **completed** (confirmed and paid), the client can leave **one review**: 1 to 5 stars and up to 1,000 characters (optional). It can't be edited or deleted afterwards. It shows on the creator's page as **"Alex R."** (first name and last initial, never the full name) with the package, and both people see it on the booking. The creator is notified. |

**What "the final payment releases" means here.** Slate never holds anyone's money: Stripe sends the balance straight to the creator's account when the client pays it. So *release* means *when the client is asked to pay*: only after they've confirmed they have the files. Holding the balance in advance and paying it out on confirmation (escrow) would need separate Stripe charges and transfers, payout rules and a dispute process, none of which is built. A client can still open the link before paying the balance.

**The link.** Only plain `https` addresses are accepted: at most 2,048 characters, every character from the URI character set (so no spaces, quotes or non-ASCII), a real-looking host (dots, a letter in the last part, so no bare IP addresses or `localhost`), no username or password in it. `DeliveryRules.cleanLink` (Swift) and `delivery_url_clean()` (SQL, also enforced by a check constraint) are the same rule, and `SlateTests/Fixtures/delivery_rules.json` holds 77 cases both test suites must agree on. Slate never fetches the link and never sees the files, and anyone who has the link can open it, so the share sheet reminds the creator to use a private one. Reviewer names are shortened the same way in both places (`ReviewRules.displayName`, `review_display_name()`), from the same fixture.

**Reviews can't be faked.** The `reviews` table is closed to the API. A review is written only by `submit_review()`, which checks that the caller is the booking's client, that the booking is completed and its receipt confirmed, and that there is no review yet (the unique constraint backs that up under a race). Public pages read through `list_reviews()` and `creator_review_summary()`, which return no booking id or reviewer id. The star average is worked out from a count and a sum, not stored.

## Messaging and notifications

**Messages.** Every booking has one conversation between its two people (Messages tab, or "Message …" on a booking). Besides what people write, the conversation records what happens to the booking, as short centred lines: *booked*, *deposit paid*, *contract signed*, *files shared* (or *link updated*), *receipt confirmed*, *balance paid*, *reviewed*, *cancelled (and what's refunded)*. Those lines are written by the database from the booking's own changes (triggers on `bookings`, `payments` and `contracts`), never by a person, so they can be trusted as a history. A text message is tidied before it is stored (line breaks, control characters; `MessageRules` and `message_clean()` share a fixture), limited to 2,000 characters and to 20 a minute, and sent with an id the app makes so a retry after a dropped connection can't post it twice. People who aren't in the booking can read and write nothing (Row Level Security plus the functions). A lapsed hold has no conversation; a cancelled or completed booking keeps its conversation, for refund questions. New lines arrive by **polling every few seconds while a conversation is open** (and every ten on the list), not a live connection.

**Notifications.** Nine kinds, grouped into five switches in *Profile → More → Notifications*: **bookings** (a new booking, a cancellation; final files shared or replaced, receipt confirmed, a review received), **contracts** (signed by both), **payments** (a deposit or balance received), **messages**, and **shoot reminders** (a day before and two hours before, for both people, for confirmed bookings only). The payment and contract notifications are sent when Stripe confirms the money, not when someone taps, and nothing is announced for a payment that was handed straight back (cancelled while paying, or a duplicate). The app asks for permission only when the person taps *Turn On* (a card on Home, or the settings screen), never at launch. Tapping a notification opens the booking or the conversation (`slate://booking/<id>`, `slate://messages/<id>`). The icon badge is the number of unread messages.

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

## The look

The look comes from a reference the product owner supplied (a dark marketplace app, "Creator Connect Pro"): a near-black page, deep violet-black cards with a thin violet-grey border, one violet accent, rounded-rectangle buttons (filled for the main action, outlined for the one beside it), pill chips, icon tiles, and a violet glow on the first screen. The palette was read off the reference's pixels: page `#04050C`, card `#0E0F1C`, chips and tiles `#1B1C31`, border `#3B334F`, accent `#8A4DF5` (the reference's `#9054F8`, nudged so white text on it clears 4.5 : 1), and `#A97BFF` for words in the accent.

Everything is a token in `DesignSystem/DesignSystem.swift`, so a change there changes every screen: `slateBackground`, `slateCard`, `slateRaised`, `slateFill`, `slateHairline`, `slateAccentText`, `slateGlow`; `card()` (with the border); `SlatePrimaryButtonStyle` / `SlateOutlineButtonStyle` (`.slatePrimary`, `.slateOutline`); chips in `Components.swift`; `slateGlowBackground()`. The accent is the `AccentColor` asset. The app opens in **Dark Mode** whatever the phone is set to; **Settings ▸ Look** switches to Light or to the system setting, and every token has a Light value (a lavender page, white cards). Segmented controls take the accent through one UIKit appearance call (`SlateAppearance`). Lists and forms use `slateCard` rows on the page background so no system gray shows (the rule is in `ios/CLAUDE.md`).

What stayed Apple-native: the system fonts in text styles, SF Symbols, the tab bar and navigation bars (the system draws them; they pick up the accent), sheets, swipe actions and Sign in with Apple's own button.

## Polish, accessibility and the widget

**What the polish pass covered.** Every screen was reviewed against Apple's Human Interface Guidelines and `CLAUDE.md`, and the findings fixed:

- **Spacing and sizes come from tokens.** Layout numbers that had crept in as literals (button label heights, icon columns, content widths, placeholder heights, date tiles, day and time buttons, the signature pad) are now `Metrics` values, so the same thing is the same size everywhere. Frames that hold text are minimums, so they grow with the text instead of clipping it.
- **Dynamic Type.** The nine fixed-point-size symbols (welcome, empty states, confirmation) now use `.heroSymbol(_:)`, which scales with the text size up to a cap. Rows that put two things side by side (a package's name and price, a booking and its status, a conversation's name and time, payment lines, review stars and date, the Home link buttons) stack at accessibility sizes (`AdaptiveStack`, `ViewThatFits`). Time buttons in the booking sheet widen with the text.
- **Dark Mode.** Signatures are dark ink on a light "paper" surface in both appearances (they were navy on dark grey, so almost invisible in Dark Mode), matching the signed PDF. The status colors used for small text (green, orange, red) are darker in Light Mode (at least 4.5 : 1 on white, worked out from the colors, not measured on screen) and the system colors in Dark Mode. The rating number is text color, with only the star orange.
- **VoiceOver.** Decorative symbols and chevrons are hidden; icon-only controls were checked and all carry labels; the rating control is one adjustable element ("swipe up to raise it"); the reviews average reads as "4.8 out of 5, from 12 reviews"; delivery, review and attention rows read as single elements with a hint.
- **Haptics and motion.** Haptics on the actions that mean something (selecting a time or tab, signing, paying, sharing files, confirming, posting a review, hiding or showing a package, copying a message, a payment that needs attention). System toggles, pickers and steppers already tap. List rows, unread badges and Home cards animate in and out with the shared springs, and everything custom stays still when Reduce Motion is on (`motionSafe`, and tile presses now respect it too).
- **Home's "Needs attention"** was a placeholder; it now lists what you actually have to do (pay a held deposit, confirm shared files, pay a balance, share final files after a shoot), most urgent first, and each row opens that booking.

**The home screen widget** shows your next confirmed booking: *when* (today, tomorrow or the date, in the shoot's own time zone), the package and who it is with. Small and medium sizes for the home screen (medium lists the next three), rectangular and inline for the lock screen. Tapping opens that booking (`slate://booking/<id>`). It never touches the network: the app writes a small file into an **App Group** whenever its bookings change (`AppModel.bookingsChanged()` → `WidgetSnapshot`), and the widget reads it. It moves on by itself as shoots finish and the day changes. The other person's name is marked privacy-sensitive, so it is hidden while the phone is locked.

To use it on a device you must register the App Group once: in your developer account add an **App Group** (default `group.com.example.slate`, set by `APP_GROUP_ID` in `Config/App.xcconfig`; change it there, in one place, if you change the bundle ID), and let Xcode add it to both the app and the *SlateWidgets* target (both entitlements files already ask for it). Without the group the app still builds and runs; the widget simply has nothing to show.

## Companies and teams

**Two kinds of account.** After Sign in with Apple a new person chooses **Just me** (an individual freelancer: everything described above) or **My company** (a team). Someone who opens a company invite link first goes straight to the invite instead. An individual can move up later, from the account switcher or Settings, without losing anything: their services and contract templates move to the company, while their profile, portfolio, bookings and every signed contract stay where they are.

**Switching accounts.** The avatar at the top of Home, Bookings, Services and Profile opens an account sheet, the way Apple's apps switch accounts: the person's own account, each company they work for, and ways to upgrade or start a company. What a tab shows follows the account: services, hours, contract templates, the portfolio and the payment account belong to the account on screen, while bookings, payments and messages always belong to the person (a company's bookings show under the company, and the jobs it gives you also show under yours). The app opens on the account you last used.

**Settings ▸ Team** (Profile ▸ ⋯ ▸ Settings) has, for the company on screen and as far as the role allows: **Members** (swipe to change a role or remove someone, tap for their team profile; pending invites below, swipe to revoke or replace a lost link), **Team calendar**, **Company settings** (the name on contracts, how bookings are assigned, who signs, payout splitting, going back to an individual account, closing), **Billing**, **Activity** (who changed bookings, contracts, prices and the team), and **My hours here**.

**Roles.** Five, one per person per company, enforced by the database and hidden in the app when a role cannot use something:

| | Owner | Admin | Manager | Creator | Viewer |
|---|---|---|---|---|---|
| Billing, payments setup, payout splitting, delete the company | ✓ | | | | |
| Company profile, invite and manage the team, services, contract templates, choose the signer, activity log | ✓ | ✓ | | | |
| Assign and manage bookings | ✓ | ✓ | ✓ | | |
| See all bookings and reports | ✓ | ✓ | ✓ | | ✓ |
| Manage their own calendar and assigned bookings | ✓ | ✓ | ✓ | ✓ | |
| See the team and its calendar | ✓ | ✓ | ✓ | ✓ | ✓ |

An Admin can invite and manage Managers, Creators and Viewers but not other Admins or the Owner. Exactly one Owner; ownership is handed over, never dropped. A company whose plan has lapsed is read only (the Owner can still pay and close it).

**Where the rules live.** Every question of the form "may this person act for that owner?" goes through `acts_for()` and `provider_access()` in SQL (`20261027000000_organizations.sql`, `20261028000000_company_booking.sql`), and is mirrored by `OrgRole`, `OrgPermission` and `RoleRules` in Swift and `LocalBackend.permits`. The matrix is `SlateTests/Fixtures/team_permissions.json`, checked by both the Swift tests and `team_rules.py`. A company is a `creator_profiles` row of kind `company` plus an `organizations` row, so its id is a profile id and packages, templates, hours, bookings and the payment account are found by it exactly as a person's are; `memberships`, `invites` (only a hash of the token is kept) and `activity_log` hang off it.

**Booking a company.** A client books the company (the booking is then given to a person) or books a named person. The company chooses how: **automatically** (default: whoever is free with the fewest upcoming bookings, ties to whoever joined first) or **by a manager**, in which case a time is offered only while there are more free people than bookings already waiting, and the booking appears under *Needs a person* on Home and Bookings. A person's hours at the company can only narrow the company's. Nobody is ever in two places: a booking blocks the person it is *assigned to*, so a person's own page and their company's are one calendar (the `bookings_no_double_booking` exclusion constraint is on `assigned_to`, and `Booking.occupant` is the same idea in Swift), and a person's own calendar busy time counts too. The same decision is made by `TeamAvailability` (Swift, for the screen and the on-device backend) and `team_availability()` / `create_booking()` (SQL).

**Contracts** are made in the company's legal name and countersigned by one **designated signer** (an Owner or Admin, or another role the Owner allows) the moment the client has signed and the deposit is paid. Who signs, and the title they sign with, are fixed when the client signs, so changing the signer never touches a contract already made. The signed PDF says "For Northlight Films LLC, Owner".

**Payments** go to the company's own Stripe Connect account (the Owner sets it up under Services ▸ Payments). With splitting on, the Owner sets a share per person and each booking records it for reports; Slate makes no transfers to members.

**Numbers you can change.** Seat minimum (10, the billing floor: a team of four is billed for ten) and maximum (250), how long an invite lives (7 days) and the grace period after a failed payment (7 days) are rows in `app_settings`, read by the app through `team_config()`. To change one, update the row, for example `update app_settings set value = '{"minimum": 5, "maximum": 100}' where key = 'seats';`. The seat maximum counts invites that are still pending. On-device the same numbers come from `TeamConfig.standard`.

### Turning on seat billing

A company pays for seats with one Stripe Billing subscription (no In-App Purchase). Until you do this, a company can be set up but takes no members and no bookings.

1. In Stripe, make a Product with a recurring monthly Price per unit (one seat) and copy the price id.
2. `supabase secrets set STRIPE_SEAT_PRICE_ID=price_...` (billing stays off without it).
3. Deploy `billing-session` (with JWT verification: it is the Owner asking), and `billing-redirect` and `billing-sync` with `--no-verify-jwt`.
4. Point the existing Stripe webhook (`stripe-webhook`) at `customer.subscription.created`, `customer.subscription.updated` and `customer.subscription.deleted` as well as the payment events. Only the webhook's signed events can record a plan.
5. Run `billing-sync` on a schedule (every 15 minutes is plenty; call it like `send-push`, with the service role key or `PUSH_CRON_SECRET`). It pushes seat changes to Stripe (a seat added is charged at once, one removed lowers the next invoice), ends the plans of closed companies and makes companies past their grace period read only.
6. To run without billing at all (a private deployment), set `billing` to `{"required": false, "grace_days": 7}`.

**Never exercised:** Stripe Billing itself (Checkout, the portal, the webhook events, proration), the Supabase calls behind the team screens against a live project, and a second real phone joining through an invite link. The SQL is tested against a real Postgres and the Swift decodes the rows that Postgres actually returned (`SlateTests/Fixtures/team_rows.json`, written by `supabase/tests/dump_team_rows.py` and checked in CI so it cannot drift).

**On a device with no server,** billing is unavailable (the Billing screen says so), and since there is no second phone, *Invite ▸ Add pretend teammate* adds someone by name to try roles, assignment and the calendar alone. Signed in as one person, `LocalBackend.actAs` (used by the tests) is how other team members' views are checked.

## Layout

```
ios/
  project.yml                 XcodeGen project definition (source of truth)
  Config/                     xcconfig, entitlements (Info.plist is generated)
  Shared/                     Code compiled into both the app and the widget (the widget's snapshot, its storage and wording)
  SlateWidgets/               The home screen and lock screen widget (WidgetKit)
  Slate/
    App/                      Entry point, root state (AppModel), tabs
    Core/                     Models, rules, AvailabilityEngine, backend protocol + Local and Supabase backends, media
    Services/                 EventKit (CalendarService), signed-PDF rendering (ContractPDF), Apple Pay (PaymentAuthorizer), notifications (NotificationService)
    DesignSystem/             Tokens, card styles, motion, shared components
    Features/                 Auth, Onboarding, Profile, Home, Services, Availability, Booking, Bookings, Contracts, Payments, Delivery (files and reviews), Messages, Notifications, Teams (account choice, switcher, settings, members, invites, calendar, billing, activity)
    Resources/                Asset catalog (accent color, app icon)
  SlateTests/                 Unit tests (rules, engine, pricing, drafts, LocalBackend, booking flow, contracts, PDF, payments)
    Fixtures/contract_golden.json   Contract text both SQL and Swift must reproduce exactly
    Fixtures/refund_golden.json     Refund amounts both SQL and Swift must agree on
    Fixtures/notification_rules.json  Message tidying, the message limit and reminder times both must agree on
    Fixtures/delivery_rules.json    Which delivery links are accepted, note and review limits, and reviewer names, both must agree on
    Fixtures/team_permissions.json  What each company role may do; Swift and Postgres both check it
    Fixtures/seat_rules.json        Seats billed and the effect of adding or removing someone; Swift and Postgres both check it
    Fixtures/team_rows.json         What the team functions really return, written by dump_team_rows.py from a real Postgres
  supabase/
    migrations/               Schema, security and the booking, contract, payment, messaging and delivery functions
    tests/                    Postgres rule tests: booking_rules.py, team_rules.py, company_rules.py, billing_rules.py, and dump_team_rows.py (--check compares its output with the Swift fixture)
    functions/                Edge Functions: delete-account, the payment ones (logic in _shared/payments.ts), send-push (_shared/push.ts, apns.ts) and the seat billing ones (billing-session, billing-redirect, billing-sync; _shared/billing.ts)
    function-tests/           Node tests and type-check for the payment, push and billing logic
```

The design system is `Slate/DesignSystem/DesignSystem.swift` (spacing, radii, colors, type scale, card styles, motion) plus `Components.swift`. Everything is built from system fonts, system colors and SF Symbols, so Dark Mode, Dynamic Type and OS-level visual updates apply automatically.

## Status of verification

Written on a Linux machine with no Xcode, so **the Swift is compiled and tested by CI, not locally.** The `iOS` workflow builds the app and runs the unit tests on a macOS runner; treat it as the source of truth. With company accounts, the team screens and the dark violet restyle it compiled and ran 646 tests with 0 failures on a macOS runner (Xcode 26.6). CI caught three real faults on the way: a team row whose `is_signer` came back null and broke decoding, a `signer_role_not_allowed` error that was read as the shorter `not_allowed`, and a test handle that on-device mode correctly treats as taken. The restyle has been checked by CI and by colour arithmetic, never by looking at it on a screen, so expect to adjust spacing and contrast the first time it runs on a phone. With delivery, reviews, the polish pass and the widget it ran 494 with 0 failures (the first compile of that work caught one error, a property wrapper with an argument but no initial value, and the fix is one line). Before that, with messaging and notifications, it ran 412 with 0 failures, including the check that Swift renders the golden contracts word for word as Postgres does, quotes the golden refunds to the cent, and tidies messages and picks reminder times from the same fixture the database is tested against. The new tests cover the message rules, the reminder planner, conversations and settings on the on-device backend, and the permission, registration and reminder flows against a stand-in for the system's notification center. (CI caught a real bug on the way: reminders waiting for a permission answer weren't cleared when the answer was no.)

The booking rules in SQL are tested for real: `supabase/tests/booking_rules.py` applies the migrations to a throwaway Postgres and tries to break them (overlaps, buffers, hours, blackouts, notice, price tampering, row level security, contract rendering and placeholder injection, signature rules, signed-PDF storage access, holds and their expiry, deposits, late and duplicate payments, balances, refunds by every policy, who may call which payment function, who can read or write a conversation, message limits and retries, unread counts, the lines and notifications each booking event produces (and none for a payment that was handed straight back), reminder windows, the push queue's claiming, retrying and clean-up, device tokens, and many clients racing for one slot, one payment report or one message). It once caught a real bug: two clients booking overlapping times at the same instant could get a deadlock error instead of "slot taken". Bookings for one creator are now serialised with an advisory lock, and the race tests passed ten runs in a row afterwards. The `Database` workflow runs it on every change to `supabase/`; you can run it locally with `PGPORT=5432 python3 supabase/tests/booking_rules.py`.

The payment and push logic in the Edge Functions (`_shared/payments.ts`, `push.ts`, `apns.ts`) is type-checked and tested with Node against fake database, Stripe and APNs objects (`cd supabase/function-tests && npm ci && npm test`): amounts and destinations come from the database, a forged or repeated webhook changes nothing, refunds are idempotent and retry only when Stripe couldn't be reached; notifications are worded as expected in the shoot's own time zone, the APNs token verifies against its public key and is reused for half an hour, dead device tokens are forgotten, failures are retried, and `send-push` refuses anyone without the service key. CI runs it too.

**Never exercised** (needs a device, an Apple ID, Stripe, Apple's push servers or a live project): Sign in with Apple, Supabase auth, storage and the Swift calls to the booking, contract, payment and messaging functions (including the signed PDF upload), **a real push notification reaching a real phone (see "Turning on notifications")**, **Stripe itself (PaymentIntents, Connect onboarding, the webhook, refunds)**, **Apple Pay on a real device**, the thin Deno wiring that connects the tested payment and push logic to the real Stripe, APNs and Supabase clients (`_shared/runtime.ts` and each function's `index.ts`), EventKit permission prompts and event writing, the photo and video picking flows, and finger-drawing a signature on a real screen. The Swift side of the Supabase calls compiles but has not talked to a database.

## Known gaps

- **Payments have never run against Stripe or Apple Pay** (see above). Expect to fix small things the first time they do.
- **The creator can't approve bookings one by one**; their saved signature is applied automatically.
- **Signed PDFs are produced by the app, not the server** (see above).
- **Contracts can't be amended after signing.** Cancelling a booking voids its contract.
- **Little runs on a schedule you haven't set up.** Expired holds are released whenever anyone books, pays, messages or lists bookings, and owed refunds are retried when the app opens or refreshes; a scheduled job (for example `pg_cron` calling `expire_holds()` and `process-refunds`) would make both prompt even when nobody opens the app. Server-side push notifications and shoot reminders need the schedule in "Turning on notifications" and send nothing without it.
- **Nothing chases anyone.** The client gets one notification when files are shared and the creator one when the client confirms; nothing repeats them. A client who never confirms leaves the balance unpayable, and one who confirms but never pays isn't followed up or flagged as overdue. There is no automatic confirmation after some number of days, which many creators would want, but it is a policy decision (and a dispute risk) that is yours to make. (`balance_due` is still a notification kind in the queue, kept for a future reminder; nothing sends it.)
- **No disputes, chargebacks, payout screens or earnings summary.** Stripe's dashboard has them.
- **Apple Pay's country comes from the device's region**, not the creator's. For creators outside that country it needs to come from their Stripe account.
- **Delivery is a link, not a file.** Slate never hosts, fetches or checks the files or the link (it can't tell that a link works, or that it has the right files in it), the client can open the link before paying the balance, and money is not held back until they confirm (see "Delivery and reviews").
- **Reviews are plain.** One per booking, no editing or deleting, no reply from the creator, no reporting or moderation (Apple's guideline 1.2 expects a way to report objectionable user content, so add one before submitting), and no photos. Only stars and text.
- **Calendar busy time is device-synced**, so it can be stale, and events written with write-only access can't be removed again on cancel.
- **Messages are fetched by polling**, every few seconds while a conversation is open, not streamed. There are no typing indicators, no read receipts shown to the other person, no photos or files, and a message can't be edited or deleted.
- **No way to report or block.** Messaging is limited to the two people on a booking, but Apple's App Review guideline 1.2 expects an app with user-generated content to offer reporting and blocking. Add them before submitting.
- **Notifications are English only, have no quiet hours or per-booking mute** (iOS Focus modes and the Show Previews setting apply), and a message's text appears in the banner. Nothing is retried for a phone that is off for more than the notification's lifetime (a day or two; a week for messages).
- **A person with no server-backed account gets only shoot reminders.** On-device, the other person is an account on the same phone, so there is nobody to send a push to.
- **Company payouts to members are a ledger, not transfers.** The Owner sets a share per person and reports show what each is owed; Slate moves no money to members. Pay them from the company's Stripe account or your payroll.
- **Team invites are links.** The Owner or an Admin shares a single-use link; no email is sent and there is no web page for someone without the app.
- **A booking left unassigned sends no reminder.** With assignment set to manual it waits in the "Needs a person" list until a Manager takes it; nothing nudges anyone.
- **Per-member services are an "Offered by" choice on a company service**, not a separate kind of service owned by a member.
- **The company screens have never talked to a live Supabase project or Stripe Billing**, and a second real phone has never joined through an invite link (see "Companies and teams").
- **Booking links don't resolve.** `slate.example` is a reserved placeholder host. The Home tab says so.
- **Apple token revocation on account deletion** is not implemented (Apple requires it). It needs a client secret signed with your Apple key; see the TODO in `supabase/functions/delete-account/index.ts`.
- **The Apple user ID is kept in `UserDefaults`**, not the Keychain. It's an identifier, not a secret, but Keychain is the better home.
- **The widget is one widget.** It shows the next bookings and nothing else: no choice of what it shows, no buttons in it, no per-creator filter. It updates when the app is running and its bookings change, and on a schedule from what it already has; a booking made from another device appears only after the app next opens or refreshes (nothing wakes the app in the background to update it).
- **Accessibility was reviewed, not tested with assistive technology.** Nobody has driven these screens with VoiceOver, Voice Control or Switch Control, at the largest accessibility text size, with Increase Contrast, or on an iPad in split view; the changes above come from reading the code against the guidelines, and the contrast figures are calculated.
- **Accent colours are tuned by calculation, not by eye.** The violet (#8A4DF5) carries white button text at about 4.7 : 1; words in the accent use a lighter violet in Dark Mode (about 6.5 : 1 on a card). Icons in the plain accent are about 4 : 1 on a dark card, which clears the 3 : 1 asked of symbols. None of it has been looked at on a screen.
- **Profile photos are centre-cropped** to a circle. There's no crop/zoom UI yet.
- **English only**; strings aren't localized yet.
- **Portfolio uploads are sequential and unretried.** A failed upload during onboarding shows an alert and the person finishes from their profile.
