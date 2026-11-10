# Getting Slate Pro into TestFlight and the App Store

Plain steps, in order. Nothing here needs you to write code. Where a step says "tell me", paste what you see (never a secret key) and I will fix the project.

**The order**

1. **Apple's developer website:** register the app's names and switch on its features (Part A).
2. **App Store Connect:** create the app's page (Part B).
3. **Xcode:** sign in with your Apple ID (Part C).
4. **TestFlight:** run one line in Terminal, then install the app on your own iPhone (Part D).
5. **The store page:** words, pictures and privacy answers (Part E).
6. **The company plan:** set up the subscription in App Store Connect and try it from TestFlight (Part G).
7. **Submit for review**, after the checklist in Part F.

Apple usually takes a day or two to approve an enrollment, and one to three days to review a first submission. Parts A to D can be done as soon as your account is active; E and F can be prepared now.

---

## Part A. Apple's developer website

Go to <https://developer.apple.com/account> and sign in with the Apple ID you enrolled with. Everything below is under **Certificates, Identifiers & Profiles** (click it on the account page).

**A1. Write down your Team ID.** On the account page, click **Membership details**. Copy the 10-character **Team ID** (letters and numbers). You will need it in Part C.

**A2. Make the App Group** (the shared box the app and its widget both use).
Identifiers ▸ the blue **+** ▸ **App Groups** ▸ Continue. Description: `Slate Pro`. Identifier: `group.com.slateproapp.app`. Continue ▸ Register.

**A3. Make the app's identifier.**
Identifiers ▸ **+** ▸ **App IDs** ▸ Continue ▸ **App** ▸ Continue.

- Description: `Slate Pro`
- Bundle ID: choose **Explicit** and type `com.slateproapp.app` (exactly, lower case)
- Under **Capabilities**, tick: **App Groups**, **Push Notifications**, **Sign in with Apple**. (Apple Pay is added later, see A6.)
- Next to **App Groups** click **Configure** and tick `group.com.slateproapp.app`. Next to **Sign in with Apple** leave it on *Enable as a primary App ID*.
- Continue ▸ Register.

**A4. Make the widget's identifier.** Same screen again: **+** ▸ App IDs ▸ App ▸ Continue.

- Description: `Slate Pro Widgets`
- Bundle ID, **Explicit**: `com.slateproapp.app.widgets`
- Capability: **App Groups**, and **Configure** it with the same `group.com.slateproapp.app`.
- Continue ▸ Register.

**A5. Make a push key** (so the server can send notifications; skip it for the very first TestFlight build if you like, notifications just stay off).
Keys ▸ **+** ▸ name `Slate Pro push` ▸ tick **Apple Push Notifications service (APNs)** ▸ Continue ▸ Register ▸ **Download**. You can download it only once. Keep the `.p8` file somewhere safe and write down the **Key ID**. Part "Turning on notifications" in [`../README.md`](../README.md) says where the server uses it. Never paste the file's contents into a chat.

**A6. Apple Pay (optional for the first build; payment links work without it).**
Identifiers ▸ **+** ▸ **Merchant IDs** ▸ Continue. Description `Slate Pro`, Identifier `merchant.com.slateproapp.app`. Then Stripe needs Apple's certificate for it: in the Stripe dashboard open *Settings ▸ Payment methods ▸ Apple Pay ▸ Add new application*, follow its steps (it gives you a file to upload to Apple and a file to bring back). When the merchant ID exists, go back to the app's identifier (A3), tick **Apple Pay Payment Processing**, click **Configure**, tick the merchant ID, Save. "Turning on real payments" in the README has the rest.

**A7. A second key, for Sign in with Apple (not needed yet).** When I add the "revoke Apple's sign-in when someone deletes their account" step (Part F), it needs one more key: Keys ▸ **+** ▸ name `Slate Pro sign in` ▸ tick **Sign in with Apple** ▸ Configure ▸ pick the `Slate Pro` app ID ▸ Save ▸ Register ▸ Download (once). Hold on to it, and I will tell you where it goes.

**A8. Register your iPhone (needed once, even for TestFlight).** A new developer account has no devices, and Apple refuses to make the signing files for a build until at least one iPhone is registered. (It says "Your team has no devices from which to generate a provisioning profile.") It also lets you install test versions straight from your Mac later.

1. Plug your iPhone into the Mac with its cable, unlock it, and tap **Trust** if it asks.
2. In Xcode choose **Window ▸ Devices and Simulators**, click your iPhone on the left, and copy the line called **Identifier** (a long code of letters and numbers).
3. On <https://developer.apple.com/account> go to **Certificates, Identifiers & Profiles ▸ Devices ▸ the blue +**. Platform **iOS**, any name (for example `My iPhone`), paste the Identifier, then **Continue** and **Register**.

---

## Part B. App Store Connect: the app's page

Go to <https://appstoreconnect.apple.com> ▸ **Apps** ▸ the blue **+** ▸ **New App**.

- Platforms: **iOS**
- Name: `Slate Pro` (it must be unique across the whole App Store; if it is taken, try `Slate Pro: Bookings`)
- Primary language: English (U.S.)
- Bundle ID: pick `Slate Pro - com.slateproapp.app` from the list (it appears once A3 is done)
- SKU: `slatepro-ios` (only you ever see it)
- User access: Full Access
- Create.

The app now has a page. Leave it empty for the moment.

**Check the bundle ID before moving on.** Open the new page and click **App Information** in the left list (under *General*). The **Bundle ID** row must read exactly `com.slateproapp.app`. If it reads anything else, the page was made for the wrong identifier, and a build can never be uploaded to it: remove the page (App Information, then **Remove App** at the bottom, which works while nothing has been uploaded) and make it again after fixing the identifier in Part A. The Bundle ID of an app page can't be changed afterwards, so this is the moment to be sure.

---

## Part C. Sign Xcode in to your Apple ID

Building for real iPhones needs Xcode to know who you are. This takes two minutes, once.

**C1.** Open Xcode. In the menu bar choose **Xcode ▸ Settings…** (or press the command key and comma), click **Accounts**, click the **+** at the bottom left, choose **Apple ID**, and sign in with the Apple ID that your developer account belongs to (Apple sends a code to your other devices). Close the window. Your name and team should now be listed.

**C2.** The app has to know your Supabase project, or the TestFlight build would open to a screen with nothing to do. If you ran `bash scripts/setup-server.sh` earlier (the step that connected the app to Supabase), there is nothing to do: the file `ios/Config/Secrets.xcconfig` exists. If not, run that first (the README, "Using a real Supabase project", says how).

---

## Part D. Your first build on your own iPhone

**D1. Run one line in Terminal.** Open Terminal (press the command key and Space, type Terminal, press Return), paste this and press Return:

```sh
cd ~ && curl -L -o slate.zip https://github.com/mikenaz5/first-one/archive/refs/heads/claude/ecstatic-curie-4456ah.zip && unzip -oq slate.zip && cd first-one-claude-ecstatic-curie-4456ah/ios && bash scripts/testflight-from-mac.sh
```

The first time it asks for your **Team ID** (10 letters and numbers, from A1); it remembers it after that. Then it builds the app for iPhones and sends it to Apple. The first run takes 10 to 20 minutes (it downloads the app's building blocks); later runs are faster. Xcode may ask permission to use your keychain: choose **Always Allow**. It ends with "Done. Build … is on its way to Apple." Add `--version 1.0.0` to the end of the line to set the version people see.

If it stops with a message, copy everything it printed and send it to me. The usual ones:

- *"Apple needs at least one iPhone registered…"*: do A8, then run the line again.
- *"Xcode doesn't have your Apple ID"*: do C1, then run the line again.
- *"Xcode couldn't make the signing files"*: check A3 and A4 (both identifiers exist, with App Groups ticked and set to `group.com.slateproapp.app`), then run the line again.
- *"The app doesn't know your Supabase project yet"*: do C2.

**D2. Wait for Apple.** In App Store Connect ▸ your app ▸ **TestFlight**, the build appears under *iOS builds* after 10 to 30 minutes of "Processing". Apple may email you that it finished. (The app declares that it uses only ordinary encryption, so the export questions are already answered.)

**D3. Put yourself on the team of testers.** Still in TestFlight: **Internal Testing** ▸ **+** ▸ name the group `Me` ▸ tick *Enable automatic distribution* ▸ add yourself (your Apple ID must be a user under *Users and Access*; you are one already) ▸ add the build.

**D4. Install it.** On your iPhone, install **TestFlight** from the App Store and sign in with the same Apple ID. Slate Pro appears; tap **Install**. This is the real app on a real phone, talking to your real Supabase project. Builds expire after 90 days; run the line again for a newer one.

**D5. Friends and creators.** Internal testing is for up to 100 people who are on your App Store Connect team. For anyone else (a photographer friend, say), make an **External Testing** group and add their email; Apple does a short review of the first external build (about a day), then they get an invite by email.

---

## Part E. The store page

Open the app's page in App Store Connect ▸ **iOS App ▸ 1.0 Prepare for Submission**. Suggested text (change anything you like; it is yours):

**Name:** Slate Pro
**Subtitle (30 characters at most):** Bookings, contracts, payments
**Category:** Business (primary), Photo & Video (secondary)
**Promotional text (170 characters at most; you can change it any time without a new review):**
Get booked, sign the contract, take the deposit and deliver the files, all in one app made for photographers, videographers and freelancers.

**Description:**

> Slate Pro is the booking app for people who get hired to make things: photographers, videographers and other freelance creators.
>
> Share your link, let clients pick a package and a time that is really free, and have the contract signed inside the booking. A booking is confirmed only when the contract is signed and the deposit is settled, so nobody gets double-booked and nobody is left with a handshake and no paperwork.
>
> FOR CREATORS
> • A public page with your portfolio, packages, add-ons and prices
> • Set your hours; your calendar's busy times keep clients off the times you're taken (only the start and end times are shared, never the titles)
> • A contract written into every booking, filled in for you and signed on the phone, with a signed PDF for both of you
> • Get paid directly to your own Stripe account, with Apple Pay, or add your own payment link and mark payments received yourself
> • Message clients, deliver photos and videos in the app or by link, and collect reviews
> • A home screen widget for your next bookings
>
> FOR COMPANIES AND STUDIOS
> • Add your team with roles, shared services, a team calendar and events
> • Bookings are assigned to the right person, with a record of who did what
>
> FOR CLIENTS
> • Free to use: find creators near you, ask a question before you book, sign, pay and receive your files
> • Keep a card on file for next time
>
> Your data is encrypted in transit and who can see what is enforced on the server. No ads and no tracking. Questions: support@slateproapp.com.

(Every line describes something the app does today. If a feature is switched off at launch, such as Apple Pay, delete its mention before submitting.)

**Keywords (100 characters at most, commas, no spaces):**
`booking,photographer,videographer,freelance,contract,invoice,deposit,client,schedule,esign,studio`

**URLs**

- Support URL: `https://slateproapp.com/support/`
- Privacy Policy URL: `https://slateproapp.com/privacy/`
- Marketing URL (optional): `https://slateproapp.com/`

**Copyright:** `2026 ` followed by the legal name of whoever runs Slate Pro.

**Age rating.** Answer the questionnaire honestly. The points that matter for this app: people can message each other and share photos and videos (user-generated content: yes), there is no web browsing, no gambling, no violence and no mature material. Real-world payments for services are not "in-app purchases".

**Screenshots.** App Store Connect lists the exact sizes when you click the screenshot box (an iPhone set is required; an iPad set too if the app runs on iPad, see Part F). The simulator can produce them: tell me when you want a set and I will add a script that takes them from the demo account.

### App Privacy answers

In App Store Connect ▸ your app ▸ **App Privacy** ▸ **Get Started**. These match the privacy manifest in the app ([`Config/PrivacyInfo.xcprivacy`](../Config/PrivacyInfo.xcprivacy)) and the privacy policy on the website. Do they match what you actually do? Read them once; Apple holds you to what you answer here.

- **Do you or your third-party partners collect data from this app?** Yes.
- **Used to track you** (tied to ads or shared with data brokers): **none**. Slate Pro has no advertising and no tracking.
- **Linked to the person's identity or device, used for App Functionality** (running the app, including preventing fraud), for each of these. The last three are collected by Stripe's payment code, which also uses them to keep and improve its software, so for those three tick **Analytics** as well:

| Apple's heading | What it is in Slate Pro |
|---|---|
| Contact Info ▸ Name | Name from Sign in with Apple or the profile |
| Contact Info ▸ Email Address | Sign-in address (may be Apple's private relay) |
| Identifiers ▸ User ID | The account's internal ID |
| Identifiers ▸ Device ID | The notification token Apple gives the phone, and the device identifier Stripe's payment code creates to prevent fraud |
| User Content ▸ Photos or Videos | Portfolio and delivered photos and videos |
| User Content ▸ Emails or Text Messages | Messages between a client and a creator |
| User Content ▸ Other User Content | Contracts and signatures, notes, reviews, calendar busy times, reports |
| Purchases ▸ Purchase History | Deposits, balances and refunds on bookings |
| Financial Info ▸ Payment Info | Saved card's brand, last four digits and expiry (Stripe keeps the number) |
| Usage Data ▸ Product Interaction | How the payment screens are used (which steps are reached), collected by Stripe's code |
| Diagnostics ▸ Performance Data | How Stripe's payment code performs (timings), collected by Stripe's code |
| Diagnostics ▸ Other Diagnostic Data | Device and software details and errors from Stripe's payment code |

**Stripe's part of this table is worded generally.** Stripe's code in the app sends some device and usage information to Stripe (see "What Stripe's software in the app collects" in the privacy policy), and Stripe's own documentation is the exact list. Before you submit, make Xcode print it: **Product ▸ Archive**, then in the Organizer select the archive and choose **Generate Privacy Report**. It merges what every code package in the app says it collects, so compare it with this table and add anything it shows that is missing here (and in `Config/PrivacyInfo.xcprivacy` and the policy page). We left Stripe's fraud-prevention signals switched on (`StripeAPI.advancedFraudSignalsEnabled`, the default) because they protect creators from stolen-card payments; that is a decision, written in `docs/ASSETS.md`.

- **Not collected by us:** location (the approximate position stays on the phone), contacts, health, browsing or search history, and our own diagnostics or crash data (the free TestFlight and App Store crash reports are Apple's; Slate Pro has no analytics tool). The only diagnostics are the ones Stripe's payment code collects, listed above.

### Notes for the App Review team

Paste this into **App Review Information ▸ Notes** and edit it:

> Slate Pro lets freelance creators (photographers, videographers) take bookings with a contract signed inside the booking, and lets clients find, book and pay them.
>
> To sign in, use "Continue with Apple". No other account is needed. (An email-code sign-in also exists for clients.)
>
> Payments for a photo shoot are for a real-world service, paid to the creator's own Stripe account, so In-App Purchase does not apply to them. The company plan (team features inside the app) is an auto-renewable In-App Purchase subscription in the group "Company plan"; there is no other way to buy it in the app.
>
> To see it: sign in with Apple, choose "My company", fill in the company's details, and the plan sheet opens. Purchases made in review are sandbox purchases and are recognised by the server.
>
> Account deletion: Settings ▸ Delete account.
> Reporting content: [say where, once report and block are built].
> Contact: support@slateproapp.com

---

## Part F. Before pressing "Submit for Review"

| | What | Who | Where it stands |
|---|---|---|---|
| ☐ | **The website is live at slateproapp.com** with the privacy policy and terms, and `python3 ios/scripts/check_site.py --release` passes (no *Draft* box, no `[[brackets]]`). Apple opens the privacy URL. | You (and a lawyer for the legal text) | Pages are written as drafts; see [`../../site/README.md`](../../site/README.md) |
| ☐ | **`support@slateproapp.com` exists** and you read it | You | Not yet |
| ☐ | **Sign-in emails work** (your own email sender, the code template pasted into Supabase) | You, with me | Parked; needs the domain's email records |
| ☐ | **Sign in with Apple works** against the real project (Supabase ▸ Authentication ▸ Providers ▸ Apple, with `com.slateproapp.app` as the client ID) | You | Needs A3 |
| ☐ | **Report and block** for messages and reviews (guideline 1.2: apps with user-written content). Files can be reported today | **Me** | Not built. Next |
| ☐ | **Revoke Sign in with Apple when an account is deleted** (guideline 5.1.1(v)) | **Me**, with the key from A7 | Not built |
| ☐ | **Something for the reviewer to try.** A sample creator with a profile, a package and a payment link on the real server, so the reviewer can book without paying real money (guideline 2.1: the app must be fully usable in review) | **Me** and you | Not built |
| ☐ | **The company plan is an In-App Purchase** (guideline 3.1.1), so Apple's rules are met. Everything in Part G is set up, the subscriptions show "Ready to Submit", and they are added to the version you submit | You, with me | Risk R9 in [`../../SPEC.md`](../../SPEC.md), resolved by decision D6 |
| ☐ | **Stripe tested in a sandbox**: connect a creator, pay a deposit, refund (see "Known gaps" in the README: none of it has run against Stripe yet) | You, with me | Not yet |
| ☐ | **iPad or iPhone only?** The app is set to run on both, but no one has tried it on an iPad. Choosing iPhone only for 1.0 means no iPad screenshots and no iPad layout to be rejected for | **You** decide | Say the word and I flip the setting |
| ☐ | **Privacy answers (Part E) match** the policy and the manifest | You | Written |
| ☐ | **A real iPhone has run it** from TestFlight, start to finish: sign in, make a profile, book, sign, pay | You | After D4 |

What is already done in the project for you: the privacy manifest (checked on every build), the app icon (1024 px, no transparency, which Apple insists on), the permission wording iOS shows (calendar, photos, location), "Delete account" inside the app, Sign in with Apple offered next to email codes, the export-encryption answer, the product name, and the upload script.

---

## Part G. The company plan: a subscription in App Store Connect

A company pays for its plan inside the app with Apple's own purchase sheet (Apple Pay, a card in your Wallet, or Apple Account balance). The first plan covers up to 5 people for $5.99 a month with a 7-day free week; bigger teams buy a bigger plan. Apple moves its screens around from time to time. If a name below isn't where I say, tell me what you see and I'll adjust.

**G1. Let Apple pay you.** In App Store Connect open **Business** (called *Agreements, Tax, and Banking* in older versions). Next to **Paid Apps** choose to set it up: accept the agreement, add your **bank account** and your **tax forms**. When its status says **Active**, subscriptions can be sold and tested. This can take a day or two for Apple to check.

**G2. Join the Small Business Program (as you planned).** Go to developer.apple.com/app-store/small-business-program and enroll. It drops Apple's cut from 30% to 15% while you earn under $1 million a year. Only the Account Holder can do it. Apply early: it starts at the beginning of Apple's next billing month after approval.

**G3. Make the group.** Open your app in App Store Connect, then **Monetization ▸ Subscriptions** (in the left list), and press **Create** under *Subscription Groups*. Name it `Company plan`. A group is the set of plans a company moves between.

**G4. Add the five plans.** Inside the group, add a subscription for each row. The **Product ID** has to match exactly (copy it); nothing else in the app or server needs changing when you do.

| Reference name | Product ID | Covers | Duration |
|---|---|---|---|
| Company, up to 5 people | `com.slateproapp.app.company.team5` | 5 | 1 month |
| Company, up to 10 people | `com.slateproapp.app.company.team10` | 10 | 1 month |
| Company, up to 15 people | `com.slateproapp.app.company.team15` | 15 | 1 month |
| Company, up to 20 people | `com.slateproapp.app.company.team20` | 20 | 1 month |
| Company, up to 25 people | `com.slateproapp.app.company.team25` | 25 | 1 month |

For each one:

1. **Price:** the first is **$5.99**. The prices of the others are yours to choose (tell me and I'll note them in the spec; the app shows whatever Apple holds, so nothing changes in the app).
2. **Localization (English):** *Display name* `Company plan, up to 5 people` (change the number), *Description* `Shared services, one calendar and bookings in your company's name, for up to 5 people.`
3. **Introductory offer:** for new subscribers, type **Free**, duration **1 week**. (Do this on all five; Apple gives one free week per person for the whole group.)
4. **Review screenshot:** a picture of the plan sheet in the app. Take it from TestFlight once the new build is on your phone (Part D). Apple needs it before it will review the plan, though not for testing.

**G5. Order the plans.** In the group, put them in order of level, the biggest (25) on top and the smallest (5) at the bottom. That is what makes moving to a bigger plan take effect at once (with Apple charging only the difference) and moving to a smaller one wait for the next renewal. Give the group a display name too: `Slate Pro company plan`.

**G6. Tell Apple where to send news.** Open the app's page, then **General ▸ App Information**, and find **App Store Server Notifications**. Paste the address below into **both** the Production Server URL and the Sandbox Server URL, and choose **Version 2**:

`https://YOUR-PROJECT.supabase.co/functions/v1/apple-notifications`

(Replace `YOUR-PROJECT` with your project's name; `bash scripts/setup-server.sh` prints the whole address for you at the end.) This is how the server hears about renewals, failed payments, refunds and cancellations.

**G7. Put the checks on the server.** Run `bash scripts/setup-server.sh` again (the same as in the README). It puts two small server functions online, `apple-verify` and `apple-notifications`, and asks for the app's **Apple ID**: the number shown under *General ▸ App Information ▸ Apple ID* on the app's page. It is not a secret. You can press Return to skip it while you are only trying things in TestFlight.

**G8. Try it.** Install the new build from TestFlight (Part D). Sign in, choose **My company**, fill in the details, and the plan sheet opens. Pick a plan and tap **Start free trial**. Apple's purchase sheet says *[Environment: Sandbox]*: you are not charged, and the plan renews every few minutes instead of every month so you can watch it. Then open **Settings ▸ Billing**: it should say *Free trial* and *Covers up to 5 people*. Try inviting a sixth person: it should offer the next plan.

**G9. When you submit the app** (Part F), open the version page and add the five subscriptions under **In-App Purchases and Subscriptions** so they go to review together with the app. The first time, Apple will not accept the app without them.

---

## Appendix: the GitHub button (not working yet)

The repository has a **TestFlight** button on GitHub (Actions) that was meant to do all of this without your Mac. It stops at signing, for a reason I traced in its logs: Xcode asks Apple for your **App Groups** (the widget and the app share data through one), and Apple answers that one request with `401 Authentication failed` when the sign-in is an API key. Every other request works with the key, which is why every check before it passes. Apple's own sign-in (your Apple ID in Xcode) can use App Groups, which is why the Terminal line in Part D works.

Making the button work needs a different way of signing (creating the certificate and signing files through Apple's web service, then signing by hand). That isn't built. What follows is how the button is set up, kept in case you want to try it later, with what its messages mean.

**G1. Make an App Store Connect key.** In App Store Connect ▸ **Users and Access** ▸ **Integrations** ▸ **App Store Connect API** ▸ **Team Keys** ▸ **Generate API Key** (or the **+**).

- Name: `GitHub upload`
- Access: **Admin** (the build signs the app for you through this key, and signing sometimes needs more than App Manager can do)
- Generate, then **Download API Key** (once; the file is called `AuthKey_XXXXXXXXXX.p8`).
- Write down the **Key ID** (in the table, next to the key) and the **Issuer ID** (at the top of the page, a long string with dashes).

**G2. Give GitHub the secrets.** On GitHub open the `first-one` repository ▸ **Settings** ▸ **Secrets and variables** ▸ **Actions** ▸ **New repository secret**. Add these one at a time (name exactly as written):

**Paste the code itself, not the words in the right-hand column.** The examples there are made up, only to show the shape. After you save, the `ASC_KEY_ID` secret should hold something like `AB12CD34EF`, never the words "The Key ID".

| Secret name | What to paste |
|---|---|
| `ASC_KEY_ID` | The 10-character Key ID from G1, for example `AB12CD34EF` |
| `ASC_ISSUER_ID` | The long Issuer ID from G1, with dashes, for example `69a6de7e-1234-47e3-e053-5b8c7c11a4d1` |
| `ASC_KEY_P8` | Open the `AuthKey_….p8` file in TextEdit, select all, copy, paste. Include the `-----BEGIN PRIVATE KEY-----` and `-----END PRIVATE KEY-----` lines |
| `APPLE_TEAM_ID` | The 10-character Team ID from A1, for example `ABCDE12345` |
| `SUPABASE_URL` | Your Supabase project address, like `https://abcdefgh.supabase.co` (Supabase ▸ Project Settings ▸ Data API) |
| `SUPABASE_PUBLISHABLE_KEY` | Supabase's **publishable** key, starting `sb_publishable_`. **Never** the secret key; the button refuses it |
| `STRIPE_PUBLISHABLE_KEY` | *Optional, for Apple Pay.* Stripe's publishable key, starting `pk_`. Never `sk_` |
| `APPLE_PAY_MERCHANT_ID` | *Optional, with the one above.* `merchant.com.slateproapp.app` |

These secrets can't be read back by anyone, including me; GitHub only hands them to the upload button's run.

**G3. Press the button.** On GitHub open the **Actions** tab ▸ **TestFlight** in the left list ▸ **Run workflow** ▸ pick the branch ▸ (leave *version* empty for now) ▸ the green **Run workflow**. It takes 15 to 25 minutes. A green tick means Apple has the build.

If it turns red, open the run, click the red step and send me the first lines of red text. The first run is where small signing messages show up, and they are quick to fix.

Two messages you may see, and what to do:

- *"The ASC_KEY_P8 secret is not a usable Apple key"* (step **Save the App Store Connect key**): the key was not pasted whole. The button already puts back a missing first or last line and lost line breaks, so this means something else was pasted. Open the `AuthKey_….p8` file in TextEdit (right-click it, **Open With**, **TextEdit**), press Cmd A then Cmd C, and on GitHub (Settings, Secrets and variables, Actions) click the pencil next to `ASC_KEY_P8` and paste it over what is there. The message says how many characters it found; a real key has 184 once the first and last lines are taken away.
- *"These secrets are not set: …"* (step **Check the secrets are all there**): it names the secrets that are missing; add them as in G2.
- *"ASC_KEY_ID should be 10 letters and numbers…"*, *"ASC_ISSUER_ID should be the long Issuer ID…"* or *"APPLE_TEAM_ID should be…"* (step **Check the Apple numbers look right**): that secret holds the wrong thing, usually the wrong one of the three numbers. The Key ID is 10 characters and is also in the key's file name (`AuthKey_XXXXXXXXXX.p8`). The Issuer ID is the long one with dashes at the top of the Team Keys page. The Team ID is 10 characters under Membership details on Apple's developer site. Stray spaces and line breaks around a pasted value are removed for you.
- *"Apple does not accept this key (answer 401, not authorized)"* (step **Ask Apple whether the key works**): the key file is fine, but the Key ID, the Issuer ID and the `.p8` file do not all belong together. Check the Key ID against the file name, check the Issuer ID is the long one from the **Team Keys** tab (not the Key ID, and not from *Individual Keys*), and make sure the `.p8` is the one downloaded for that same key. If in doubt, make a new Team key (Admin access) and replace all three secrets.
- *"Apple recognises the key but will not let it in (answer 403)"*: the key was made with too little access; make a new one with **Admin**.
- *"Apple shows no app with the bundle ID com.slateproapp.app for this key"* (step **Ask Apple whether the key works**): the key is real, but it belongs to a different Apple team than the one where the app page was made, or the app page uses another bundle ID. The message lists the apps and identifiers the key can see. In App Store Connect click your name at the top right to see which teams you are in, switch to the team that has the "Slate Pro App" page, and make the key there (Users and Access, Integrations, Team Keys); then replace `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8`. Use that team's Team ID for `APPLE_TEAM_ID`.
- *"APPLE_TEAM_ID is not the team that owns this app"* (same step), or *"No Account for Team"* in the build: the Team ID secret is a different 10-character code from the one that owns the app. The message names the right one; put it in the `APPLE_TEAM_ID` secret. The Team ID is under **Membership details** on <https://developer.apple.com/account>; the Key ID looks the same (10 characters) but is a different thing.

---

## After the first release

- **New version:** run the Terminal line from D1 again with `--version 1.0.1` on the end. The build number goes up on its own.
- **Choose phased release** on the version page so the update reaches people over a week, not all at once.
- Apple will require builds made with a newer Xcode from time to time; your Mac's Xcode needs to be recent enough; update it from the App Store.
