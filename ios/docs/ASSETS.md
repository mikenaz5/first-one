# Where everything in Slate Pro comes from

**The rule: nothing is fetched from somebody else's server to be shown in the app or on its website.** A picture, font, sound,
video or script that lives on another company's server is two problems at once. Is it ours to show (copyright)? And that
server learns who opened the app, from where and when (data). So every asset is either:

1. **carried inside the app** (a file in the app, listed below with where it came from),
2. **drawn by the app's own code** (no file at all),
3. **provided by iOS itself** (system fonts and symbols, used through the system, never copied out), or
4. **a person's own upload, stored in our own Supabase project** (their photos and files, with their permission in the Terms).

`scripts/check_assets.py` enforces this on every build (CI fails if code starts reaching somewhere new, a file is added without
a row here, the website loads anything from another address, or a code package has no licence notice). If you add or change an
asset, change this file in the same commit. If a row is missing for something you know is in the app, tell me and I will
document it or replace it.

---

## 1. Files carried inside the app

| File | What it is | Who made it | Licence |
|---|---|---|---|
| `Slate/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png` | The app icon, 1024 px: three bars on a dark rounded square | Made for Slate Pro in this project (the same three bars as the opening animation). No stock or third-party artwork | Ours |
| `Slate/Resources/ThirdPartyNotices.txt` | The licence notices of the code packages and fonts the app carries, shown in Settings under About | Written by `scripts/update_notices.py` from each one's own licence file | Each one's own (sections 3 and 5) |
| `Slate/Resources/Fonts/Inter-Regular.otf` | Inter Regular, the text of the contract PDF | The Inter Project Authors (rsms/inter), release 4.0 (`extras/otf` in Inter-4.0.zip from github.com/rsms/inter/releases), taken 10 Nov 2026, unmodified | SIL Open Font License 1.1 |
| `Slate/Resources/Fonts/Inter-SemiBold.otf` | Inter SemiBold, headings in the contract PDF | As above | SIL Open Font License 1.1 |
| `Slate/Resources/Fonts/Inter-Bold.otf` | Inter Bold, the title and the signatures heading in the contract PDF | As above | SIL Open Font License 1.1 |
| `Slate/Resources/Fonts/JetBrainsMono-Regular.ttf` | JetBrains Mono Regular, the ids and the hash in the contract PDF | The JetBrains Mono Project Authors (JetBrains/JetBrainsMono), release 2.304 (`fonts/ttf`), taken 10 Nov 2026, unmodified | SIL Open Font License 1.1 |
| `Config/PrivacyInfo.xcprivacy` | Apple's privacy manifest: what the app collects and why | Ours | Ours |

Colours (`AccentColor`, `LaunchBackground` and the design tokens in `DesignSystem.swift`) are values, not files, and are ours.
**The only bundled fonts are the four above, and they are used only to set the contract PDF** (see section 3). There are no bundled photos, videos or sounds, and no image files other than the icon.

## 2. Drawn by the app's own code

| What | Where | Note |
|---|---|---|
| The opening animation (three bars, glint, name) | `DesignSystem/LaunchAnimation.swift` | Shapes and colours in code |
| Sample creators' pictures (on-device mode only) | `Core/SampleArt.swift` | A sky, sun and hill drawn from numbers, so no one's photograph is ever used and a sample can't be mistaken for a real person's work |
| Placeholder covers and initials avatars | `Features/Client/FeaturedCreatorsView.swift`, `DesignSystem/Components.swift` | Gradients and letters |
| The signature pad and typed signature | `Features/Contracts/` | Strokes the person draws; the typed one uses the font below |
| The home screen widget | `SlateWidgets/` | Text and shapes, reads a small file, never the network |
| The contract PDF | `Services/ContractPDF.swift` | Drawn with the system's PDF renderer from text |
| Marketing videos (the opening animation, the teaser) | Made from the same code-drawn animation, kept outside the app | No third-party footage or music. The videos that show the name set it in **Inter** (SIL Open Font License 1.1, free for commercial use, including in video; no font file is distributed). The teaser has no text |

## 3. Provided by iOS (used through the system, not copied)

| What | Licence note |
|---|---|
| **San Francisco** (the system font, every screen of the app and the widget) | Used through the system's own font calls on Apple devices. Don't copy the font files out of iOS. The website and the sign-in email only *name* the system font stack (`-apple-system`, `system-ui`, ...), which each visitor's own device resolves; nothing is served. The contract PDF does **not** use it (see below), so no piece of it travels inside a PDF |
| **Snell Roundhand** (the typed signature, `SnellRoundhand-Bold`) | A font built into iOS, called by name on screen. Nothing is bundled. If it is missing the code falls back to the italic system font. In the contract PDF the typed signature is drawn as a **picture** of the name, so no copy of the font goes into the file |
| **SF Symbols** (every icon in the app) | Apple's licence allows them in apps and mock-ups for Apple platforms. **Do not use them on the website, in the app icon, in a logo, or in marketing artwork.** The website uses none |
| Apple Pay, Sign in with Apple, the purchase sheet | Apple's own screens; Apple's marketing and button guidelines apply to anything we draw about them |

### Every font, in one place

| Where | Font | How | Font files shipped |
|---|---|---|---|
| App screens and the widget | San Francisco (system), its rounded design for the opening animation and initials, its monospaced design for codes and this licenses page | The system, through text styles | None |
| Typed signature on screen | Snell Roundhand (built into iOS) | By name, with a system fallback | None |
| Typed signature in the contract PDF | Snell Roundhand, drawn as a picture | Rendered to an image first | None, and none copied into the PDF |
| Contract PDF body, headings and certificate | **Inter** (Regular, SemiBold, Bold) and **JetBrains Mono** (Regular, for ids and the hash), SIL Open Font License 1.1 | Carried in `Slate/Resources/Fonts`, loaded by `Services/PDFFonts.swift`; the PDF renderer embeds the letters it draws, which the licence expressly allows ("the requirement for fonts to remain under this license does not apply to any document created using the fonts"). If a file can't be loaded the system font is used, and a test fails | The four files in section 1, with the licence text in `ThirdPartyNotices.txt` |
| The website | System font stack (names only: `-apple-system`, `BlinkMacSystemFont`, `SF Pro Text`, `Segoe UI`, `Roboto`, `Helvetica`, `Arial`) | The visitor's own device | None |
| The sign-in email | System stack, and `SF Mono`, `Menlo`, `Consolas` for the code | The reader's own device | None |
| Design previews | System stacks (and the same names for the signature) | The viewer's own device | None |
| Marketing videos that show the name | Inter (SIL OFL 1.1) | Rendered into the video | None distributed |

`scripts/check_assets.py` fails the build for a font file on the site, a font file in the app outside `Slate/Resources/Fonts`, from a
family not on its list, without a row here or without its licence text in `ThirdPartyNotices.txt`; and for an `@font-face`, a web-font
link, a custom font used in code outside the places above, or a font name in the website or email that isn't a device font.
`ContractPDFTests` checks that every font inside a produced PDF is Inter or JetBrains Mono.

## 4. People's own content, and the links they give us

| What | Where it lives | Notes |
|---|---|---|
| Profile photos and portfolio pictures and videos | Our Supabase Storage (`avatars`, `portfolio`), always uploaded, never an address pasted in. The database stores a path, and the app builds the address from our project's own | `SupabaseBackend.publicURL` is the only place those addresses are made. Terms section 6: people upload only what they have the right to share and give us permission to store and show it |
| Delivered photos and videos | Our private storage (`deliveries`), deleted 30 days after delivery | Shown through short-lived signed addresses |
| A delivery link or a payment link a creator pastes | In our database as text | Shown as a link and opened in the browser only when someone taps it. The app never fetches it, never shows a picture from it |

## 5. Code packages and fonts (open source, used under their licences)

Their licences ask that the copyright notice and the licence text travel with the app. They do: `Slate/Resources/ThirdPartyNotices.txt`
holds the full text for every package the build uses (including the ones these bring in) and for both font families, and **Settings ▸
About ▸ Open-source licences** shows it. CI fails if the build resolves a package with no notice, or a font file has none.

| Package | Used for | Licence |
|---|---|---|
| `supabase-swift` | Talking to our own Supabase project: sign-in, database, storage, server functions | MIT |
| `stripe-ios-spm` (the `StripeApplePay` part only) | Paying a deposit or balance with Apple Pay | MIT |
| `swift-asn1`, `swift-crypto`, `swift-http-types` (Apple; brought in by the packages above) | Reading certificates and signatures, cryptography, and web request types, inside the packages above | Apache License 2.0 (their NOTICE files are in the notices too) |
| `swift-clocks`, `swift-concurrency-extras`, `xctest-dynamic-overlay` (Point-Free; brought in by `supabase-swift`) | Timing and testing helpers inside `supabase-swift` | MIT |
| Inter (fonts) | Setting the contract PDF's text | SIL Open Font License 1.1 |
| JetBrains Mono (fonts) | Setting the ids and the hash in the contract PDF | SIL Open Font License 1.1 |

## 6. Who the app talks to

| Who | Why | What they receive |
|---|---|---|
| **Our Supabase project** | Everything: accounts, bookings, files, messages | What the person does in the app |
| **Stripe** | Apple Pay payments, saved cards, creators' payout accounts | Payment details through Apple Pay (never the card number to us). **Stripe's own code in the app also sends Stripe some device and usage information (fraud prevention and its own diagnostics); that is decided and disclosed, see section 9** |
| **Apple** | Sign in with Apple, push notifications, the company plan purchase (App Store), Apple Pay | What those services need |
| **The links people tap** (a delivery link, a payment link, "Add to Google Calendar", our own site) | They open in the browser when tapped | Nothing from us. The app loads nothing from them |

Nothing in the app loads a picture, font, script, advertisement, analytics or tracking tool from any other company.

## 7. The website (`../site`)

Plain pages and one style sheet. No external fonts, scripts, pictures, frames, forms or analytics; the checker fails the build if one
appears. The system font stack is used, so no font files are served.

## 8. Adding an asset: the checklist

1. Make it, or get it with a licence that allows use in a commercial app (and say which in the table above, with where it came from
   and the date). "Found online" is not a source.
2. Put the file in the app, or draw it in code. Never point the app or the site at an address on someone else's server.
3. Add the row here. Run `python3 scripts/check_assets.py`.
4. If the asset collects anything (an SDK, a font service, a video player), say so in `Config/PrivacyInfo.xcprivacy`, the privacy
   policy and `docs/APP_STORE.md`'s App Privacy answers.

## 9. Decisions made

- **Fonts inside the contract PDF (decided 10 Nov 2026).** A PDF carries the letters it uses, and Apple's licence for its system
  fonts is for use on Apple devices through the system, so a PDF sent to another person must not contain pieces of them. The PDF
  is now set in Inter and JetBrains Mono (SIL Open Font License 1.1, which expressly allows embedding in documents), carried in the
  app, with their licence text in the notices. The PDFs look slightly different from before. Screens, the widget and everything
  else keep the system font.

- **Stripe's code in the app (decided 10 Nov 2026).** Paying with Apple Pay and saving a card use Stripe's iOS code. By default it
  sends Stripe some device and usage information, to detect fraud (`StripeAPI.advancedFraudSignalsEnabled`, on by default, which
  protects creators from stolen-card payments) and to measure and improve its own library (no switch). The decision is to **leave
  it on and say so**: the privacy policy has a section "What Stripe's software in the app collects", the privacy manifest
  (`Config/PrivacyInfo.xcprivacy`) and `docs/APP_STORE.md`'s App Privacy answers list Device ID, Product Interaction, Performance
  Data and Other Diagnostic Data for it (linked, never for tracking). The exact list is Stripe's, and it is worded generally
  here: before submitting, **Product ▸ Archive ▸ Organizer ▸ Generate Privacy Report** shows what each package declares, and
  anything missing from our list should be added in all three places. Our Stripe code never sets a tracking flag and the app
  has no tracking domains.

## 10. Decisions waiting

Nothing at the moment.
