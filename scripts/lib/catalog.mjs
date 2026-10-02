import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const SLUG = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
const COLOR = /^#[0-9a-f]{6}$/i;
const MAX_TAGS = 13; // marketplace listing limits
const MAX_TAG_LENGTH = 20;
const MAX_TITLE_LENGTH = 140;

export function loadConfig(root, env = process.env) {
  const config = {
    currency: 'USD',
    paymentProvider: 'our payment provider',
    refundDays: 14,
    contactEmail: '',
    customDomain: '',
    headHtml: '',
    ...JSON.parse(readFileSync(join(root, 'site.config.json'), 'utf8')),
  };
  if (env.SITE_URL) config.baseUrl = env.SITE_URL; // local preview
  else if (config.customDomain) config.baseUrl = `https://${config.customDomain}`;
  config.baseUrl = config.baseUrl.replace(/\/+$/, '');
  config.basePath = new URL(config.baseUrl).pathname.replace(/\/+$/, '');
  return config;
}

const isText = (v) => typeof v === 'string' && v.trim() !== '';
const isTextList = (v) => Array.isArray(v) && v.length > 0 && v.every(isText);

function validate(p, dirName) {
  const errs = [];
  if (!SLUG.test(p.slug ?? '')) errs.push('slug must be lowercase letters, digits and hyphens');
  else if (p.slug !== dirName) errs.push(`slug "${p.slug}" must match the folder name "${dirName}"`);
  for (const key of ['name', 'tagline']) if (!isText(p[key])) errs.push(`${key} is required`);
  if (!(typeof p.price === 'number' && p.price > 0)) errs.push('price must be a number above 0');
  if (!COLOR.test(p.accent ?? '')) errs.push('accent must be a hex colour like #1f6f78');
  if (!isTextList(p.description)) errs.push('description must be a non-empty list of paragraphs');
  if (!isTextList(p.features)) errs.push('features must be a non-empty list of strings');
  if (!isTextList(p.contents)) errs.push('contents must be a non-empty list of strings');
  if (!Array.isArray(p.faq) || !p.faq.every((f) => isText(f?.q) && isText(f?.a))) {
    errs.push('faq must be a list of { q, a } objects');
  }
  if (!Array.isArray(p.tags) || p.tags.length > MAX_TAGS || !p.tags.every(isText)) {
    errs.push(`tags must be a list of at most ${MAX_TAGS} strings`);
  } else if (p.tags.some((t) => t.length > MAX_TAG_LENGTH)) {
    errs.push(`each tag must be ${MAX_TAG_LENGTH} characters or fewer`);
  }
  if (p.checkoutUrl && !/^https:\/\/\S+$/.test(p.checkoutUrl)) errs.push('checkoutUrl must be an https URL (or empty)');
  if (isText(p.name) && isText(p.tagline) && `${p.name} | ${p.tagline}`.length > MAX_TITLE_LENGTH) {
    errs.push(`"name | tagline" must fit a ${MAX_TITLE_LENGTH}-character listing title`);
  }
  return errs;
}

function listFiles(dir) {
  if (!existsSync(dir)) return [];
  return readdirSync(dir, { withFileTypes: true })
    .filter((e) => e.isFile() && !e.name.startsWith('.'))
    .map((e) => ({ name: e.name, path: join(dir, e.name) }))
    .sort((a, b) => a.name.localeCompare(b.name));
}

/**
 * Load products/<slug>/product.json. Returns { products, problems }.
 * Products with problems are left out; callers decide whether problems are fatal.
 */
export function loadProducts(root) {
  const base = join(root, 'products');
  const problems = [];
  const loaded = new Map();

  for (const entry of readdirSync(base, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const jsonPath = join(base, entry.name, 'product.json');
    if (!existsSync(jsonPath)) {
      problems.push(`${entry.name}: missing product.json`);
      continue;
    }
    let product;
    try {
      product = JSON.parse(readFileSync(jsonPath, 'utf8'));
    } catch (err) {
      problems.push(`${entry.name}: product.json is not valid JSON (${err.message})`);
      continue;
    }
    const errs = validate(product, entry.name);
    if (errs.length) {
      problems.push(...errs.map((e) => `${entry.name}: ${e}`));
      continue;
    }
    product.checkoutUrl ||= '';
    product.ready = product.checkoutUrl !== '';
    product.files = listFiles(join(base, entry.name, 'files'));
    loaded.set(product.slug, product);
  }

  for (const product of loaded.values()) {
    if (product.bundleOf) {
      const parts = product.bundleOf.map((slug) => loaded.get(slug));
      const missing = product.bundleOf.filter((slug) => !loaded.get(slug));
      const nested = parts.filter((part) => part?.bundleOf).map((part) => part.slug);
      if (missing.length || nested.length || product.bundleOf.length < 2) {
        problems.push(
          `${product.slug}: bundleOf needs at least two valid, non-bundle products (missing: ${missing.join(', ') || 'none'}; nested bundles: ${nested.join(', ') || 'none'})`,
        );
        loaded.delete(product.slug);
        continue;
      }
      product.parts = parts;
      product.savings = Math.max(0, parts.reduce((sum, part) => sum + part.price, 0) - product.price);
    } else if (product.files.length === 0) {
      problems.push(`${product.slug}: files/ is empty, so there is nothing to sell`);
      loaded.delete(product.slug);
    }
  }

  // Bundles last on the shelf, otherwise by name.
  const products = [...loaded.values()].sort(
    (a, b) => Boolean(a.bundleOf) - Boolean(b.bundleOf) || a.name.localeCompare(b.name),
  );
  return { products, problems };
}
