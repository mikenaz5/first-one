import { licenseClauses } from './license.mjs';

export const esc = (value) =>
  String(value).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

export function money(amount, currency) {
  return new Intl.NumberFormat('en-US', {
    style: 'currency',
    currency,
    minimumFractionDigits: Number.isInteger(amount) ? 0 : 2,
  }).format(amount);
}

// Neutral decorative cover: a spreadsheet motif tinted with the product accent.
// Deterministic (seeded from the slug) so builds are reproducible.
export function coverSvg(product) {
  let seed = [...product.slug].reduce((h, c) => (h * 31 + c.charCodeAt(0)) >>> 0, 7);
  const rand = () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 2 ** 32);
  const a = product.accent;
  let rows = '';
  for (let r = 0; r < 7; r++) {
    const y = 118 + r * 34;
    rows += `<rect x="64" y="${y}" width="512" height="26" rx="4" fill="#fff" opacity="${r % 2 ? 0.16 : 0.26}"/>`;
    rows += `<rect x="76" y="${y + 9}" width="${60 + Math.floor(rand() * 90)}" height="8" rx="4" fill="#fff" opacity=".8"/>`;
    rows += `<rect x="${440 + Math.floor(rand() * 40)}" y="${y + 9}" width="${40 + Math.floor(rand() * 20)}" height="8" rx="4" fill="#fff" opacity=".8"/>`;
  }
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 640 400" role="img" aria-label="${esc(product.name)}">
<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="${a}"/><stop offset="1" stop-color="${a}" stop-opacity=".72"/></linearGradient></defs>
<rect width="640" height="400" rx="20" fill="url(#g)"/>
<rect x="64" y="56" width="512" height="44" rx="8" fill="#000" opacity=".28"/>
<rect x="84" y="73" width="150" height="10" rx="5" fill="#fff"/>
${rows}
</svg>
`;
}

export const css = `:root{--bg:#fbfaf7;--text:#1d2327;--muted:#59636b;--card:#fff;--line:#e3e1da;--brand:#1f6f78;--on-brand:#fff;--soft:#eef5f5}
@media (prefers-color-scheme:dark){:root{--bg:#121516;--text:#e9ecee;--muted:#a3adb4;--card:#1a1e20;--line:#2a3033;--brand:#6cc0c9;--on-brand:#0b1213;--soft:#182224}}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--text);font:17px/1.6 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
a{color:var(--brand)}
.wrap{max-width:960px;margin:0 auto;padding:0 20px}
.skip{position:absolute;left:-999px}.skip:focus{left:12px;top:12px;background:var(--card);padding:8px 12px;z-index:9}
header.site{border-bottom:1px solid var(--line)}
header.site .wrap{display:flex;align-items:center;justify-content:space-between;gap:16px;padding-top:16px;padding-bottom:16px;flex-wrap:wrap}
.brand{font-weight:700;font-size:1.15rem;color:var(--text);text-decoration:none}
nav a{margin-left:18px;color:var(--muted);text-decoration:none}nav a:hover{color:var(--text)}
main{padding:40px 0 64px}
h1{font-size:clamp(1.9rem,5vw,2.6rem);line-height:1.15;margin:0 0 12px}
h2{font-size:1.4rem;margin:40px 0 12px}
.lead{font-size:1.2rem;color:var(--muted);max-width:40rem}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(270px,1fr));gap:20px;margin-top:28px}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;overflow:hidden;display:flex;flex-direction:column}
.card img{display:block;width:100%;height:auto}
.card .body{padding:16px 18px 20px;display:flex;flex-direction:column;gap:6px;flex:1}
.card h3{margin:0;font-size:1.1rem}.card h3 a{color:var(--text);text-decoration:none}.card h3 a:hover{text-decoration:underline}
.card p{margin:0;color:var(--muted);font-size:.95rem}
.price{font-weight:700;font-size:1.25rem}
.badge{display:inline-block;background:var(--soft);color:var(--brand);border-radius:999px;padding:2px 10px;font-size:.8rem;font-weight:600;margin-left:8px;vertical-align:middle}
.btn{display:inline-block;background:var(--brand);color:var(--on-brand);font-weight:700;text-decoration:none;padding:12px 22px;border-radius:10px;border:0}
.btn:hover{filter:brightness(1.08)}.btn:focus-visible,a:focus-visible,summary:focus-visible{outline:3px solid var(--brand);outline-offset:3px}
.btn.disabled{background:var(--line);color:var(--muted);cursor:not-allowed}
.product{display:grid;gap:32px;grid-template-columns:1fr}
@media (min-width:760px){.product{grid-template-columns:1fr 1fr;align-items:start}}
.product img{width:100%;height:auto;border-radius:14px}
.buy{display:flex;align-items:center;gap:16px;flex-wrap:wrap;margin:20px 0 8px}
.fine{color:var(--muted);font-size:.9rem;margin:0}
ul.tick{padding:0;list-style:none}ul.tick li{padding-left:28px;position:relative;margin:8px 0}ul.tick li:before{content:"\\2713";position:absolute;left:0;color:var(--brand);font-weight:700}
details{border-top:1px solid var(--line);padding:12px 0}details:last-of-type{border-bottom:1px solid var(--line)}
summary{cursor:pointer;font-weight:600}details p{margin:8px 0 0;color:var(--muted)}
.points{display:grid;gap:20px;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));margin-top:48px}
.points h3{margin:0 0 4px;font-size:1.05rem}.points p{margin:0;color:var(--muted)}
.prose{max-width:42rem}.prose h2{margin-top:32px}
footer{border-top:1px solid var(--line);color:var(--muted);font-size:.9rem;padding:24px 0}
footer .wrap{display:flex;justify-content:space-between;gap:12px;flex-wrap:wrap}
`;

export function layout(config, { title, description, path, body, noindex = false, jsonld = null, type = 'website' }) {
  const url = `${config.baseUrl}${path}`;
  const full = path === '/' ? `${config.name}: ${config.tagline}` : `${title} | ${config.name}`;
  const base = config.basePath;
  const year = config.year ?? new Date().getFullYear();
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(full)}</title>
<meta name="description" content="${esc(description)}">
<link rel="canonical" href="${esc(url)}">
${noindex ? '<meta name="robots" content="noindex">\n' : ''}<meta property="og:type" content="${type}">
<meta property="og:site_name" content="${esc(config.name)}">
<meta property="og:title" content="${esc(full)}">
<meta property="og:description" content="${esc(description)}">
<meta property="og:url" content="${esc(url)}">
<meta name="twitter:card" content="summary">
<link rel="stylesheet" href="${base}/assets/style.css">
${jsonld ? `<script type="application/ld+json">${JSON.stringify(jsonld).replace(/</g, '\\u003c')}</script>\n` : ''}${config.headHtml}
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
<header class="site"><div class="wrap">
<a class="brand" href="${base}/">${esc(config.name)}</a>
<nav aria-label="Main"><a href="${base}/#products">Products</a><a href="${base}/refunds/">Refunds</a><a href="${base}/terms/">Terms</a></nav>
</div></header>
<main id="main"><div class="wrap">
${body}
</div></main>
<footer><div class="wrap">
<span>&copy; ${year} ${esc(config.name)}</span>
<span><a href="${base}/privacy/">Privacy</a>${config.contactEmail ? ` &middot; <a href="mailto:${esc(config.contactEmail)}">${esc(config.contactEmail)}</a>` : ''}</span>
</div></footer>
</body>
</html>
`;
}

const saveBadge = (config, p) => (p.savings > 0 ? `<span class="badge">Save ${money(p.savings, config.currency)}</span>` : '');

export function homePage(config, products) {
  const base = config.basePath;
  const cards = products
    .map(
      (p) => `<article class="card">
<a href="${base}/p/${p.slug}/" tabindex="-1" aria-hidden="true"><img src="${base}/assets/${p.slug}.svg" alt="" width="640" height="400" loading="lazy"></a>
<div class="body">
<h3><a href="${base}/p/${p.slug}/">${esc(p.name)}</a></h3>
<p>${esc(p.tagline)}</p>
<p class="price">${money(p.price, config.currency)}${saveBadge(config, p)}${p.ready ? '' : '<span class="badge">Coming soon</span>'}</p>
</div>
</article>`,
    )
    .join('\n');
  const body = `<h1>${esc(config.tagline)}</h1>
<p class="lead">Ready-made spreadsheets for freelancers and anyone who wants a clear picture of their money. Pay once, download instantly, and keep them forever.</p>
<section id="products" aria-labelledby="products-h"><h2 id="products-h">Products</h2>
<div class="grid">
${cards}
</div></section>
<div class="points">
<div><h3>Pay once</h3><p>No subscription. One payment and the files are yours to keep.</p></div>
<div><h3>Instant download</h3><p>Your files arrive straight after checkout. Nothing to wait for.</p></div>
<div><h3>Your data stays with you</h3><p>Plain spreadsheet files. No account, no sign-up, nothing is uploaded anywhere.</p></div>
</div>`;
  return layout(config, {
    title: config.name,
    description: `${config.tagline} Ready-made spreadsheet templates for freelancers and personal finance.`,
    path: '/',
    body,
  });
}

export function productPage(config, p, others) {
  const base = config.basePath;
  const buy = p.ready
    ? `<a class="btn" href="${esc(p.checkoutUrl)}" rel="noopener">Buy now</a>`
    : '<span class="btn disabled" aria-disabled="true">Coming soon</span>';
  const guarantee = config.refundDays > 0 ? ` &middot; ${config.refundDays}-day refund` : '';
  const body = `<div class="product">
<div><img src="${base}/assets/${p.slug}.svg" alt="" width="640" height="400"></div>
<div>
<h1>${esc(p.name)}</h1>
<p class="lead">${esc(p.tagline)}</p>
<div class="buy"><span class="price">${money(p.price, config.currency)}${saveBadge(config, p)}</span>${buy}</div>
<p class="fine">One-time payment &middot; instant download${guarantee}</p>
</div>
</div>
<h2>About</h2>
${p.description.map((para) => `<p>${esc(para)}</p>`).join('\n')}
<h2>Highlights</h2>
<ul class="tick">${p.features.map((f) => `<li>${esc(f)}</li>`).join('')}</ul>
<h2>What you get</h2>
<ul class="tick">${p.contents.map((f) => `<li>${esc(f)}</li>`).join('')}</ul>
<h2>Questions</h2>
${p.faq.map((f) => `<details><summary>${esc(f.q)}</summary><p>${esc(f.a)}</p></details>`).join('\n')}
${
  others.length
    ? `<h2>More from ${esc(config.name)}</h2>\n<div class="grid">${others
        .map(
          (o) =>
            `<article class="card"><div class="body"><h3><a href="${base}/p/${o.slug}/">${esc(o.name)}</a></h3><p>${esc(o.tagline)}</p><p class="price">${money(o.price, config.currency)}</p></div></article>`,
        )
        .join('')}</div>`
    : ''
}`;
  const jsonld = p.ready
    ? {
        '@context': 'https://schema.org',
        '@type': 'Product',
        name: p.name,
        description: p.description.join(' '),
        offers: {
          '@type': 'Offer',
          price: p.price.toFixed(2),
          priceCurrency: config.currency,
          availability: 'https://schema.org/InStock',
          url: `${config.baseUrl}/p/${p.slug}/`,
        },
      }
    : null;
  return layout(config, {
    title: p.name,
    description: p.tagline,
    path: `/p/${p.slug}/`,
    body,
    noindex: !p.ready,
    jsonld,
  });
}

export function policyPage(config, kind) {
  const contact = config.contactEmail
    ? `email <a href="mailto:${esc(config.contactEmail)}">${esc(config.contactEmail)}</a>`
    : 'use the contact details on this website';
  const pages = {
    privacy: {
      title: 'Privacy',
      description: `How ${config.name} handles your data.`,
      html: `<p>This website is a static site. It does not set cookies and has no accounts or sign-ups. ${
        config.headHtml
          ? 'It includes a third-party script, configured by the site owner, to measure visits. See that provider&rsquo;s privacy policy for how it handles data.'
          : 'It does not use analytics or tracking scripts.'
      }</p>
<p>When you buy, you leave this site. Your purchase is handled by ${esc(config.paymentProvider)}, which collects your payment and contact details and delivers your download. We never see your card details. Read their privacy policy for how they use your data.</p>
<p>To ask about data we hold about you, ${contact}.</p>`,
    },
    refunds: {
      title: 'Refunds',
      description: `Refund policy for ${config.name}.`,
      html:
        config.refundDays > 0
          ? `<p>If a product is not what you hoped for, ask for a refund within ${config.refundDays} days of buying and you will get one. No long explanations needed.</p>
<p>To ask, ${contact}, and include the email address you used at checkout.</p>`
          : `<p>Because these are digital files delivered instantly, sales are final. If a file is broken or does not open, ${contact} and we will fix it or make it right.</p>`,
    },
    terms: {
      title: 'Terms',
      description: `Licence and terms for ${config.name} products.`,
      html: `${licenseClauses(config)
        .map(([h, t]) => `<h2>${esc(h)}</h2><p>${esc(t)}</p>`)
        .join('\n')}
<p>These terms sit alongside the checkout terms of ${esc(config.paymentProvider)}, which handles payment.</p>`,
    },
  };
  const page = pages[kind];
  return layout(config, {
    title: page.title,
    description: page.description,
    path: `/${kind}/`,
    body: `<div class="prose"><h1>${page.title}</h1>\n${page.html}</div>`,
  });
}

export function notFoundPage(config) {
  return layout(config, {
    title: 'Page not found',
    description: 'This page does not exist.',
    path: '/404.html',
    noindex: true,
    body: `<div class="prose"><h1>Page not found</h1><p>That page does not exist. <a href="${config.basePath}/">Browse the products</a>.</p></div>`,
  });
}
