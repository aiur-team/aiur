const forbiddenPatterns = [
  /its-everdred/i,
  /its-applekid/i,
  /\/home\/[a-z0-9_-]+\//i,
  /ghp_[A-Za-z0-9]/,
  /github_pat_/i,
  /sk-[A-Za-z0-9]{8}/,
  /\bAIUR-\d+\b/,
  /Human operator/,
];

export function assertSyntheticContent({ url, html, visibleText, marker, markers }) {
  const present = markers ? markers.length > 0 && markers.every((text) => html.includes(text)) : /example/i.test(html) && html.includes(marker);

  if (!present) {
    throw new Error(`Refusing to capture ${url}: synthetic fixture markers are missing`);
  }

  for (const pattern of forbiddenPatterns) {
    if (pattern.test(visibleText) || pattern.test(html)) {
      throw new Error(`Refusing to capture ${url}: ${pattern} matched real operator state`);
    }
  }

  const identifiers = visibleText.match(/\b[A-Z]{2,5}-\d{2,6}\b/g) ?? [];
  const foreign = identifiers.filter((identifier) => !identifier.startsWith("EX-"));

  if (foreign.length > 0) {
    throw new Error(
      `Refusing to capture ${url}: non-fixture ticket identifiers present (${[...new Set(foreign)].join(", ")})`,
    );
  }
}

const expectedModels = [
  { name: "Codex", used: [61, 47] },
  { name: "Claude", used: [34, 58] },
];

export function assertSyntheticMeters({ url, modelRows, required }) {
  if (!required && modelRows.length === 0) return;

  for (const expected of expectedModels) {
    const row = modelRows.find((html) => html.includes(`>${expected.name}</span>`));

    if (!row || expected.used.some((percent) => !row.includes(`width:${percent}%`))) {
      throw new Error(`Refusing to capture ${url}: ${expected.name} model meter does not match the synthetic fixture`);
    }
  }
}

// Zero is what a defaulted or broken meter shows, so only non-zero readings prove
// the strip is drawing the fixture.
export function expectedUsage(usage) {
  return [...usage.apis, ...usage.providers]
    .map((row) => ({
      name: row.name,
      used: [row.session, row.weekly, ...(row.lines ?? [])]
        .flatMap((window) => window?.acc ?? [])
        .concat(row.credits?.pct ?? [])
        .filter((percent) => Number.isInteger(percent) && percent > 0),
    }))
    .filter((row) => row.used.length > 0);
}

export function assertSyntheticUsage({ url, rows, expected }) {
  if (expected.length === 0) throw new Error(`Refusing to capture ${url}: the fixture has no non-zero usage readings to compare`);

  for (const { name, used } of expected) {
    const row = rows.find((candidate) => candidate.name === name);

    if (!row || used.some((percent) => !row.widths.includes(`${percent}%`))) {
      throw new Error(`Refusing to capture ${url}: ${name} usage meter does not match the synthetic fixture`);
    }
  }
}
