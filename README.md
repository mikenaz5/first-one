# Tidy Sheets

A digital products store built to run with almost no upkeep: a static storefront on free hosting, checkout and delivery handled by a merchant-of-record provider, and automated deploys and health checks. It launches with two spreadsheet products and a bundle.

**What "self-sustaining" means here.** Fixed costs are $0, nothing is fulfilled by hand, and the repo watches itself and emails you when something breaks. It does not mean customers appear on their own. Getting found is the one job this repo cannot do for you, so read [Honest expectations](#honest-expectations).

## Products

| Product | Price | What it does |
| --- | --- | --- |
| Freelancer Money Tracker | $19 | Invoices, due dates and overdue flags, expenses, monthly profit, suggested tax set-aside |
| Subscription Auditor | $9 | Recurring costs per month and year, renewal flags, potential savings |
| Freelancer Finance Bundle | $24 | Both. The "save" badge is calculated from the component prices |

Each ships as an `example` file (sample data) and a `blank` file. Prices are placeholders; change them in `products/<slug>/product.json`.

## What runs itself

| Job | Handled by | Your part |
| --- | --- | --- |
| Hosting | GitHub Pages (free) | None |
| Deploy | `deploy.yml` on every push to `main`, and each 2 January | None |
| Payment, delivery, sales tax and VAT | Merchant-of-record checkout (Lemon Squeezy, Polar, Gumroad or similar) | One-time setup. You still report your own income |
| Is the site up? Do checkout links work? | `health.yml`, weekly. Opens an issue (you get an email) and closes it when fixed | Fix it when alerted, see [docs/RUNBOOK.md](docs/RUNBOOK.md) |
| Dependency rot | Zero npm dependencies. Dependabot updates the GitHub Actions monthly | Merge a PR now and then |
| Broken spreadsheet changes | `sheets.yml` recalculates every file in LibreOffice and checks the totals | None |
| Customer questions | None | Answer the occasional email |
| Finding customers | None | You |

## Launch checklist (one time, 1 to 2 hours)

I could not do these for you. They need your accounts, identity or money.

1. **Create `main`.** This branch is the only one in the repo, and the workflows run on `main`. Run `git push origin <this-branch>:main`, then make `main` the default branch (Settings > Branches).
2. **Turn on Pages.** Settings > Pages > Source: GitHub Actions. The first deploy runs on the push to `main`.
3. **Open the spreadsheets in the apps you plan to advertise** (Excel, Google Sheets, Numbers). I verified the formulas and totals in LibreOffice only. Fix anything odd in `tools/make_spreadsheets.py`, then run `npm run sheets && npm run sheets:verify`.
4. **Open a merchant-of-record account.** Compare current fees and payout terms yourself. Create one product per row of the table above. Upload the matching zip, which you get from the `fulfillment-packages` artifact on the latest Deploy run or from `npm run package` (`out/packages/`).
5. **Connect the buy buttons.** Paste each checkout link into `checkoutUrl` in `products/<slug>/product.json` and push. "Coming soon" turns into "Buy now", and the product enters the sitemap.
6. **Set `contactEmail`** in `site.config.json`. Use a dedicated address. It appears on the site and in every download.
7. **Check the legal text.** The refund policy, terms and licence (`scripts/lib/render.mjs`, `scripts/lib/license.mjs`) are plain-language templates, not legal advice. Match `refundDays` to what your provider allows, and have someone qualified review the text.
8. **Check the brand name.** I picked "Tidy Sheets" without a trademark or domain search. Rename it in `site.config.json` if it clashes.
9. **Optional, about $10 to $15 a year:** a custom domain. Set `customDomain`, add a CNAME record to `<your-user>.github.io`, then enable it in Settings > Pages and tick "Enforce HTTPS".
10. **Run `npm run check:strict`.** It should print no warnings before you announce anything.

## Honest expectations

- **Nobody will find this by default.** A new store with no audience usually makes few or no sales. The fastest lever is marketplace listings. `out/listings/<slug>.md` has a title, description and tags (13 tags of 20 characters or fewer, which fits Etsy's limits) for each product. Marketplaces have their own rules about digital goods and AI-assisted work, so read them before listing.
- **Spreadsheet templates are a crowded, low-price market.** The value here is that the products work, the store costs nothing to hold, and adding a product takes minutes. Expect to add products and listings over time.
- **Taxes and obligations are yours.** A merchant of record handles sales tax and VAT collection on sales. Income tax on your profit, and any business registration your country requires, remain your job.
- **Support is a human job.** Keep the inbox under watch, since a refund request that goes unanswered turns into a chargeback.

## Commands

```
npm test                 unit tests (zip writer, validation, escaping, build, packaging)
npm run build            storefront into dist/
npm run package          upload-ready zips and listing kits into out/
npm run check            validate products and list what is still missing
npm run check:strict     same, but fails on anything missing (pre-launch gate)
npm run check:online     also fetch the live site and every checkout link
npm run sheets           regenerate the .xlsx files (needs: pip install -r tools/requirements.txt)
npm run sheets:verify    recalculate them in LibreOffice and check totals (needs soffice)
```

To preview locally: `SITE_URL=http://localhost:8080 npm run build && python3 -m http.server 8080 -d dist`.

## Adding a product

1. Create `products/<slug>/product.json`. Copy an existing one: `slug` (must match the folder), `name`, `tagline`, `price`, `accent`, `description`, `features`, `contents`, `faq`, `tags`, and `checkoutUrl` (empty until the product is for sale).
2. Put the sellable files in `products/<slug>/files/`. For a bundle, set `"bundleOf": ["slug-a", "slug-b"]` and leave `files/` empty.
3. `npm test && npm run build`. Validation rejects bad prices, over-long tags, non-HTTPS checkout links and empty products.
4. Push to `main`.

## Layout

```
site.config.json   brand, domain, contact, currency, refund window
products/          one folder per product: product.json + files/
scripts/           build, package, check (plain Node 22, no dependencies)
tools/             spreadsheet generator and verifier (Python, only needed when editing templates)
test/              node:test suite
.github/workflows/ ci, deploy, health, sheets
docs/RUNBOOK.md    what to do when something breaks, and the monthly check-in
```
