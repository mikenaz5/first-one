// Launch readiness and health checks.
//   node scripts/check.mjs            offline: validate products and list what is still missing
//   node scripts/check.mjs --strict   offline, and fail on anything missing (run before announcing)
//   node scripts/check.mjs --online   also fetch the live site and every checkout link (used by the weekly health job)
import { load } from './lib/site.mjs';

const root = new URL('..', import.meta.url).pathname;
const args = new Set(process.argv.slice(2));
const { config, products, problems } = load(root);
const errors = [...problems];
const warnings = [];

if (!config.contactEmail) warnings.push('site.config.json: contactEmail is empty, so customers have no way to reach you');
const forSale = products.filter((p) => p.ready);
if (forSale.length === 0) warnings.push('No product has a checkoutUrl yet, so nothing can be bought');
for (const p of products.filter((p) => !p.ready)) warnings.push(`${p.slug}: no checkoutUrl, shown as "Coming soon"`);
if (/^https:\/\/[^/]+\.github\.io/.test(config.baseUrl) && !config.customDomain) {
  warnings.push('Using the free github.io address. Set customDomain once you have a domain');
}

// Network checks. 403/429 usually mean "bot protection", not "broken", so those only warn.
async function probe(label, url) {
  try {
    const res = await fetch(url, { redirect: 'follow', signal: AbortSignal.timeout(20_000), headers: { 'user-agent': 'store-health-check' } });
    if (res.ok) return;
    if (res.status === 403 || res.status === 429) warnings.push(`${label}: ${url} answered ${res.status} (blocks automated checks, verify by hand)`);
    else errors.push(`${label}: ${url} answered ${res.status}`);
  } catch (err) {
    errors.push(`${label}: ${url} unreachable (${err.cause?.code ?? err.cause?.errors?.[0]?.code ?? err.message})`);
  }
}

if (args.has('--online')) {
  await probe('site', `${config.baseUrl}/`);
  for (const p of forSale) {
    await probe(`${p.slug} page`, `${config.baseUrl}/p/${p.slug}/`);
    await probe(`${p.slug} checkout`, p.checkoutUrl);
  }
}

for (const w of warnings) console.log(`warning: ${w}`);
for (const e of errors) console.log(`ERROR: ${e}`);
console.log(`${products.length} products, ${forSale.length} for sale, ${errors.length} errors, ${warnings.length} warnings`);
process.exit(errors.length || (args.has('--strict') && warnings.length) ? 1 : 0);
