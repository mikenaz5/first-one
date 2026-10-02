import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { loadConfig, loadProducts } from './catalog.mjs';
import { createZip } from './zip.mjs';
import { licenseText } from './license.mjs';
import { coverSvg, css, homePage, notFoundPage, policyPage, productPage, money } from './render.mjs';

function write(file, content) {
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, content);
}

function freshDir(root, outDir) {
  const out = resolve(outDir);
  const rel = relative(resolve(root), out);
  // Never wipe the project itself, a parent of it, or anything outside it that isn't clearly a build dir.
  if (rel === '' || rel.startsWith('..') || !/^(dist|out)(\/|$)/.test(rel + '/')) {
    throw new Error(`Refusing to clear ${out}: output must be dist/ or out/ inside the project`);
  }
  rmSync(out, { recursive: true, force: true });
  mkdirSync(out, { recursive: true });
  return out;
}

export function load(root, env) {
  const config = loadConfig(root, env);
  const { products, problems } = loadProducts(root);
  return { config, products, problems };
}

/** Build the static storefront into outDir. Throws if any product is invalid. */
export function buildSite({ root, outDir, env = process.env }) {
  const { config, products, problems } = load(root, env);
  if (problems.length) throw new Error(`Product problems:\n  ${problems.join('\n  ')}`);
  const out = freshDir(root, outDir);
  const pages = [];
  const emit = (path, html, indexed = true) => {
    write(join(out, path === '/' ? 'index.html' : `${path.slice(1)}index.html`), html);
    if (indexed) pages.push(path);
  };

  write(join(out, 'assets', 'style.css'), css);
  emit('/', homePage(config, products));
  for (const p of products) {
    write(join(out, 'assets', `${p.slug}.svg`), coverSvg(p));
    const others = products.filter((o) => o.slug !== p.slug);
    emit(`/p/${p.slug}/`, productPage(config, p, others), p.ready);
  }
  for (const kind of ['privacy', 'refunds', 'terms']) emit(`/${kind}/`, policyPage(config, kind));
  write(join(out, '404.html'), notFoundPage(config));

  const urls = pages.map((p) => `  <url><loc>${config.baseUrl}${p}</loc></url>`).join('\n');
  write(join(out, 'sitemap.xml'), `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls}\n</urlset>\n`);
  write(join(out, 'robots.txt'), `User-agent: *\nAllow: /\nSitemap: ${config.baseUrl}/sitemap.xml\n`);
  if (config.customDomain) write(join(out, 'CNAME'), `${config.customDomain}\n`);

  return { pages, ready: products.filter((p) => p.ready).length, total: products.length };
}

function readme(config, p, files) {
  return [
    `Thank you for buying ${p.name}.`,
    '',
    'Files in this download:',
    ...files.map((f) => `  ${f}`),
    '',
    'Open the "example" file first to see how everything works with sample data.',
    'Then use the "blank" file as your own working copy.',
    '',
    `Questions or problems? ${config.contactEmail ? `Email ${config.contactEmail}.` : 'Use the contact details on the website.'}`,
    'Your licence is in LICENSE.txt.',
    '',
  ].join('\n');
}

function listing(config, p, files) {
  return `# ${p.name}: marketplace listing kit

Price: ${money(p.price, config.currency)}
Checkout link (own site): ${p.checkoutUrl || '(not set yet)'}

## Title
${p.name} | ${p.tagline}

## Description
${p.description.join('\n\n')}

Highlights:
${p.features.map((f) => `- ${f}`).join('\n')}

What you get:
${p.contents.map((f) => `- ${f}`).join('\n')}

${p.faq.map((f) => `Q: ${f.q}\nA: ${f.a}`).join('\n\n')}

## Tags (${p.tags.length})
${p.tags.join(', ')}

## Files to upload
Upload the zip from out/packages/${p.slug}.zip, or the individual files:
${files.map((f) => `- ${f}`).join('\n')}
`;
}

/** Zip each product for upload to the checkout provider, plus a listing kit per product. */
export function packageProducts({ root, outDir, env = process.env }) {
  const { config, products, problems } = load(root, env);
  if (problems.length) throw new Error(`Product problems:\n  ${problems.join('\n  ')}`);
  const out = freshDir(root, outDir);
  const results = [];
  for (const p of products) {
    const entries = [];
    if (p.parts) {
      for (const part of p.parts) {
        for (const f of part.files) entries.push({ name: `${part.name}/${f.name}`, data: readFileSync(f.path) });
      }
    } else {
      for (const f of p.files) entries.push({ name: f.name, data: readFileSync(f.path) });
    }
    const names = entries.map((e) => e.name);
    entries.unshift(
      { name: 'README.txt', data: Buffer.from(readme(config, p, names)) },
      { name: 'LICENSE.txt', data: Buffer.from(licenseText(config)) },
    );
    write(join(out, 'packages', `${p.slug}.zip`), createZip(entries));
    write(join(out, 'listings', `${p.slug}.md`), listing(config, p, names));
    results.push({ slug: p.slug, files: entries.length });
  }
  return results;
}
