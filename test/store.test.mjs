import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createZip, crc32 } from '../scripts/lib/zip.mjs';
import { loadConfig, loadProducts } from '../scripts/lib/catalog.mjs';
import { buildSite, packageProducts } from '../scripts/lib/site.mjs';
import { esc, money } from '../scripts/lib/render.mjs';

const REPO = new URL('..', import.meta.url).pathname;
const roots = [];
const hasUnzip = (() => {
  try {
    execFileSync('unzip', ['-v'], { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
})();

function product(slug, extra = {}) {
  return {
    slug,
    name: `Product ${slug}`,
    tagline: 'A tagline',
    price: 10,
    accent: '#336699',
    description: ['One paragraph.'],
    features: ['A feature'],
    contents: ['A file'],
    faq: [{ q: 'Question?', a: 'Answer.' }],
    tags: ['one', 'two'],
    ...extra,
  };
}

function makeRoot(products, config = {}) {
  const root = mkdtempSync(join(tmpdir(), 'store-test-'));
  roots.push(root);
  writeFileSync(join(root, 'site.config.json'), JSON.stringify({ name: 'Test Shop', tagline: 'Tagline', baseUrl: 'https://example.com/shop', ...config }));
  mkdirSync(join(root, 'products'), { recursive: true });
  for (const [slug, { json, files = { 'a.txt': 'hello' } }] of Object.entries(products)) {
    mkdirSync(join(root, 'products', slug, 'files'), { recursive: true });
    writeFileSync(join(root, 'products', slug, 'product.json'), JSON.stringify(json));
    for (const [name, body] of Object.entries(files)) writeFileSync(join(root, 'products', slug, 'files', name), body);
  }
  return root;
}

test.after(() => roots.forEach((r) => rmSync(r, { recursive: true, force: true })));

test('crc32 matches the standard check value', () => {
  assert.equal(crc32(Buffer.from('123456789')), 0xcbf43926);
});

test('createZip is valid, round-trips and is deterministic', { skip: !hasUnzip }, () => {
  const root = makeRoot({});
  const entries = [
    { name: 'a.txt', data: Buffer.from('hello hello hello hello hello hello') },
    { name: 'dir/b.bin', data: Buffer.from([0, 1, 2, 3, 250]) },
    { name: 'ünï.txt', data: Buffer.alloc(0) },
  ];
  const zip = createZip(entries);
  assert.deepEqual(zip, createZip(entries));
  const file = join(root, 't.zip');
  writeFileSync(file, zip);
  execFileSync('unzip', ['-tq', file]);
  assert.equal(execFileSync('unzip', ['-p', file, 'a.txt']).toString(), 'hello hello hello hello hello hello');
  assert.deepEqual([...execFileSync('unzip', ['-p', file, 'dir/b.bin'])], [0, 1, 2, 3, 250]);
});

test('catalog reports every kind of bad product and keeps the good ones', () => {
  const root = makeRoot({
    good: { json: product('good') },
    'bad-price': { json: product('bad-price', { price: 0 }) },
    'wrong-slug': { json: product('other') },
    'many-tags': { json: product('many-tags', { tags: Array.from({ length: 14 }, (_, i) => `t${i}`) }) },
    'long-tag': { json: product('long-tag', { tags: ['x'.repeat(21)] }) },
    'http-link': { json: product('http-link', { checkoutUrl: 'http://insecure.example/buy' }) },
    'no-files': { json: product('no-files'), files: {} },
    'lone-bundle': { json: product('lone-bundle', { bundleOf: ['good'] }) },
    'ghost-bundle': { json: product('ghost-bundle', { bundleOf: ['good', 'missing'] }), files: {} },
  });
  const { products, problems } = loadProducts(root);
  assert.deepEqual(products.map((p) => p.slug), ['good']);
  const text = problems.join('\n');
  for (const needle of ['bad-price: price', 'wrong-slug: slug', 'many-tags: tags', 'long-tag: each tag', 'http-link: checkoutUrl', 'no-files: files/ is empty', 'lone-bundle: bundleOf', 'ghost-bundle: bundleOf']) {
    assert.match(text, new RegExp(needle.replace('/', '\\/')), needle);
  }
});

test('bundle savings are computed from component prices', () => {
  const root = makeRoot({
    a: { json: product('a', { price: 19 }) },
    b: { json: product('b', { price: 9 }) },
    ab: { json: product('ab', { price: 24, bundleOf: ['a', 'b'] }), files: {} },
  });
  const { products, problems } = loadProducts(root);
  assert.deepEqual(problems, []);
  assert.equal(products.find((p) => p.slug === 'ab').savings, 4);
  assert.equal(products.at(-1).slug, 'ab', 'bundles are listed last');
});

test('config: custom domain wins over baseUrl, SITE_URL wins over both, basePath is derived', () => {
  assert.equal(loadConfig(makeRoot({}), {}).basePath, '/shop');
  const custom = loadConfig(makeRoot({}, { customDomain: 'shop.example.org' }), {});
  assert.equal(custom.baseUrl, 'https://shop.example.org');
  assert.equal(custom.basePath, '');
  assert.equal(loadConfig(makeRoot({}, { customDomain: 'shop.example.org' }), { SITE_URL: 'http://localhost:9/' }).baseUrl, 'http://localhost:9');
});

test('escaping and money formatting', () => {
  assert.equal(esc(`<img src=x onerror="a('b')">&`), '&lt;img src=x onerror=&quot;a(&#39;b&#39;)&quot;&gt;&amp;');
  assert.equal(money(19, 'USD'), '$19');
  assert.equal(money(9.5, 'USD'), '$9.50');
});

test('built site: escapes content, gates unsold products, prefixes base path', () => {
  const root = makeRoot(
    {
      live: { json: product('live', { name: 'Live <b>One</b>', checkoutUrl: 'https://pay.example/live' }) },
      soon: { json: product('soon') },
    },
    { customDomain: 'shop.example.org', headHtml: '<script defer src="https://stats.example/s.js"></script>' },
  );
  const out = join(root, 'dist');
  const summary = buildSite({ root, outDir: out });
  assert.equal(summary.ready, 1);

  const live = readFileSync(join(out, 'p/live/index.html'), 'utf8');
  assert.ok(!live.includes('<b>One</b>'), 'product name must be escaped');
  assert.ok(live.includes('Live &lt;b&gt;One&lt;/b&gt;'));
  assert.ok(live.includes('href="https://pay.example/live"'));
  assert.ok(live.includes('"@type":"Product"'), 'ready products carry structured data');
  assert.ok(!live.includes('noindex'));
  assert.ok(live.includes('stats.example'), 'headHtml is injected');

  const soon = readFileSync(join(out, 'p/soon/index.html'), 'utf8');
  assert.ok(soon.includes('noindex'));
  assert.ok(soon.includes('Coming soon'));
  assert.ok(!soon.includes('"@type":"Product"'));

  const sitemap = readFileSync(join(out, 'sitemap.xml'), 'utf8');
  assert.ok(sitemap.includes('https://shop.example.org/p/live/'));
  assert.ok(!sitemap.includes('/p/soon/'), 'unsold products stay out of the sitemap');
  assert.equal(readFileSync(join(out, 'CNAME'), 'utf8').trim(), 'shop.example.org');
  assert.ok(readFileSync(join(out, 'privacy/index.html'), 'utf8').includes('third-party script'));
  for (const f of ['index.html', '404.html', 'robots.txt', 'assets/style.css', 'assets/live.svg', 'refunds/index.html', 'terms/index.html']) {
    assert.ok(existsSync(join(out, f)), f);
  }
});

test('built site without a custom domain links under the github.io style base path', () => {
  const root = makeRoot({ a: { json: product('a') } });
  buildSite({ root, outDir: join(root, 'dist') });
  const home = readFileSync(join(root, 'dist/index.html'), 'utf8');
  assert.ok(home.includes('href="/shop/p/a/"'));
  assert.ok(home.includes('href="/shop/assets/style.css"'));
  assert.ok(!existsSync(join(root, 'dist/CNAME')));
});

test('build refuses to clear directories that are not dist/ or out/ inside the project', () => {
  const root = makeRoot({ a: { json: product('a') } });
  writeFileSync(join(root, 'keep.txt'), 'precious');
  for (const bad of [root, join(root, 'products'), join(root, '..'), tmpdir()]) {
    assert.throws(() => buildSite({ root, outDir: bad }), /Refusing to clear/);
  }
  assert.equal(readFileSync(join(root, 'keep.txt'), 'utf8'), 'precious');
  assert.ok(existsSync(join(root, 'products/a/product.json')));
});

test('build fails loudly on invalid products instead of publishing a partial store', () => {
  const root = makeRoot({ a: { json: product('a') }, b: { json: product('b', { price: -1 }) } });
  assert.throws(() => buildSite({ root, outDir: join(root, 'dist') }), /b: price/);
});

test('packaging: product zips carry files, README and LICENSE; bundles combine their parts', { skip: !hasUnzip }, () => {
  const root = makeRoot(
    {
      a: { json: product('a', { name: 'Alpha' }), files: { 'a.xlsx': 'AAAA' } },
      b: { json: product('b', { name: 'Beta' }), files: { 'b.xlsx': 'BBBB' } },
      ab: { json: product('ab', { price: 15, bundleOf: ['a', 'b'] }), files: {} },
    },
    { contactEmail: 'help@example.com' },
  );
  const out = join(root, 'out');
  packageProducts({ root, outDir: out });
  const list = (slug) => execFileSync('unzip', ['-Z1', join(out, `packages/${slug}.zip`)]).toString().trim().split('\n').sort();
  assert.deepEqual(list('a'), ['LICENSE.txt', 'README.txt', 'a.xlsx']);
  assert.deepEqual(list('ab'), ['Alpha/a.xlsx', 'Beta/b.xlsx', 'LICENSE.txt', 'README.txt']);
  assert.equal(execFileSync('unzip', ['-p', join(out, 'packages/ab.zip'), 'Beta/b.xlsx']).toString(), 'BBBB');
  assert.match(execFileSync('unzip', ['-p', join(out, 'packages/a.zip'), 'LICENSE.txt']).toString(), /Do not resell/);
  const listing = readFileSync(join(out, 'listings/a.md'), 'utf8');
  assert.ok(listing.includes('## Tags (2)'));
  assert.ok(listing.includes('Alpha | A tagline'), 'listing title is "name | tagline"');
  assert.match(execFileSync('unzip', ['-p', join(out, 'packages/a.zip'), 'README.txt']).toString(), /Email help@example\.com/);
});

test('the committed products are valid and fit marketplace listing limits', () => {
  const { products, problems } = loadProducts(REPO);
  assert.deepEqual(problems, []);
  assert.ok(products.length >= 3);
  for (const p of products) {
    assert.ok(`${p.name} | ${p.tagline}`.length <= 140, `${p.slug} title length`);
    assert.ok(p.tags.length <= 13 && p.tags.every((t) => t.length <= 20), `${p.slug} tags`);
  }
  for (const p of products.filter((p) => !p.bundleOf)) {
    assert.ok(p.files.some((f) => f.name.endsWith('-example.xlsx')) && p.files.some((f) => f.name.endsWith('-blank.xlsx')), `${p.slug} ships example and blank files`);
  }
});
