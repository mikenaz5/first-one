// Zip each product for upload to the checkout provider, plus listing kits, into out/.   node scripts/package.mjs
import { packageProducts } from './lib/site.mjs';

const root = new URL('..', import.meta.url).pathname;
try {
  for (const { slug, files } of packageProducts({ root, outDir: `${root}out` })) {
    console.log(`out/packages/${slug}.zip (${files} files), out/listings/${slug}.md`);
  }
} catch (err) {
  console.error(err.message);
  process.exit(1);
}
