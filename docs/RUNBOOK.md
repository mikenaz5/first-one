# Runbook

## When a "Store health check failed" issue appears

Read the report in the issue. Each line names what failed.

| Message | Likely cause | Fix |
| --- | --- | --- |
| `site: ... unreachable` or `answered 404` | Pages is off, the last deploy failed, or the domain or DNS changed | Actions > Deploy storefront: re-run the latest run. Settings > Pages: check the source is GitHub Actions. Custom domain: check DNS and that the CNAME in Pages settings matches `customDomain` |
| `<slug> page: ... answered 404` | The product folder was renamed or removed | Restore it, or ignore if you retired it on purpose (clear its `checkoutUrl`) |
| `<slug> checkout: ... answered 404` or `410` | The product was unpublished or deleted at the provider | Republish it there, or paste the new link into `checkoutUrl` |
| `<slug> checkout: ... unreachable` | Provider outage or a mistyped link | Open the link yourself. Retry from the Health check workflow (Run workflow) |
| `warning: ... answered 403` | The provider blocks automated requests. Not an error | Open the link in a browser once to confirm it works |

The issue closes itself on the next passing run. To check right away: Actions > Health check > Run workflow.

## Monthly check-in (about 15 minutes)

1. Open the provider dashboard: sales, refunds, disputes, payout status.
2. Answer any support email.
3. Merge any Dependabot pull request once CI is green.
4. Look at the Actions tab for failed runs.

## Changing a price or text

Edit `products/<slug>/product.json` (or `site.config.json`), run `npm test`, and push to `main`. Change the price at the provider too, since the checkout page is what customers pay.

## Changing a spreadsheet

Edit `tools/make_spreadsheets.py`, then `npm run sheets && npm run sheets:verify`. Upload the new zip (`npm run package`) to the provider so new buyers get the update. If you change a total in the example data, update the expected numbers in `tools/verify_spreadsheets.py`.
