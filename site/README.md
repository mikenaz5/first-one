# slateproapp.com

The website for Slate Pro: a front page, a support page, and the privacy policy and terms that Apple asks for. It is plain
HTML and CSS (no build step), so any web host that serves a folder can publish it.

| Address | File |
|---|---|
| `/` | `index.html` |
| `/support/` | `support/index.html` |
| `/privacy/` | `privacy/index.html` |
| `/terms/` | `terms/index.html` |

The app links to `/privacy`, `/terms` and `/support` and mails `support@slateproapp.com`
(`AppConfig` in `ios/Slate/Core/Models.swift`). `python3 ios/scripts/check_site.py` fails if the app and the pages drift apart, and CI
runs it. Because the booking links are `slateproapp.com/<name>`, a creator can't choose a name that matches one of these pages
(`privacy`, `terms`, `support`, `help`, `about`, `login` and a few more are reserved).

## Before you publish

1. The privacy policy and terms are **drafts**. Fill in every `[[double bracket]]` (the company's legal name and address, the
   copyright contact, the limit of liability, the governing law) and have a lawyer read them. Then delete the yellow "Draft" box at the top
   of each page. `python3 ios/scripts/check_site.py --release` fails until both are done.
2. Make sure the mailbox `support@slateproapp.com` exists (in Google Workspace an alias is enough) and that you read it.

## Publishing (pick one)

- **Netlify Drop** is the easiest: go to app.netlify.com/drop, drag the `site` folder onto the page, and you get a working
  address straight away. Then **Domain management ▸ Add a domain** and enter `slateproapp.com`; Netlify tells you which records to add.
- **Cloudflare Pages**: connect this repository, leave the build command empty and set the output folder to `site`.
- GitHub Pages also works, but a private repository needs a paid GitHub plan for it.

Wherever you bought the domain, add only the records the host asks for (usually an `A` or `CNAME` record for `slateproapp.com`
and one for `www`). **Leave the existing `MX` records alone**: they are what delivers your `@slateproapp.com` email.

## After it is live

Open `https://slateproapp.com/privacy/` on your phone to check it. In App Store Connect (Apps ▸ Slate Pro ▸ App Information) paste
`https://slateproapp.com/privacy/` as the Privacy Policy URL, and `https://slateproapp.com/support/` as the Support URL.
