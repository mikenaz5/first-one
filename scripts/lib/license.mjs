// Licence terms shown on the Terms page and bundled into every download as LICENSE.txt.
// This is plain-language boilerplate, not legal advice. Have it reviewed before you rely on it.

export function licenseClauses(config) {
  const support = config.contactEmail ? `Email ${config.contactEmail}` : 'Use the contact details on the website';
  return [
    ['Your licence', 'You may use these files for yourself and for your own business, on any devices you own.'],
    ['What you may not do', 'Do not resell, share, upload or redistribute the files, with or without changes. Do not sell them as part of another product or template pack.'],
    ['Not advice', 'The files are planning tools. Nothing in them is financial, tax, accounting or legal advice. Check your own situation with a qualified professional.'],
    ['No warranty', 'The files are provided as they are. You are responsible for checking that figures are right before relying on them, and for backing up your own data.'],
    ['Support', `${support} if something does not work.`],
  ];
}

export function licenseText(config) {
  const lines = [`${config.name}: licence`, ''];
  for (const [heading, body] of licenseClauses(config)) lines.push(`${heading}`, body, '');
  return lines.join('\n');
}
