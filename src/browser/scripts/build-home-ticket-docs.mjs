import assert from 'node:assert/strict';

// The production renderer has no Markdown backslash escapes. Refuse text that
// would acquire formatting absent from the design's escaped literal content.
export function exportTicketDocs(rows) {
  return Object.fromEntries(Array.from(rows, ({ id, sum, scope, done, author }) => {
    for (const text of [sum, ...scope, ...done]) {
      assert.equal(typeof text, 'string');
      assert.ok(!/[`*[]/.test(text) && !/^(?:[#>\-]|\d+\.)/m.test(text), `Markdown-active fixture text for ${id}: ${text}`);
    }
    const body_md = `${sum}\n\n#### Scope\n\n${scope.map(x => '- ' + x).join('\n')}\n\n#### Done when\n\n${done.map(x => '- ' + x).join('\n')}`;
    return [id.replace(/^AIUR-/, ''), { body_md, author }];
  }));
}
