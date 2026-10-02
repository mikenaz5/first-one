// Build the storefront into dist/.   node scripts/build.mjs
import { buildSite } from './lib/site.mjs';

const root = new URL('..', import.meta.url).pathname;
try {
  const { pages, ready, total } = buildSite({ root, outDir: `${root}dist` });
  console.log(`Built ${pages.length} indexed pages. ${ready} of ${total} products are for sale.`);
} catch (err) {
  console.error(err.message);
  process.exit(1);
}
