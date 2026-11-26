defmodule VoiceConverse.ClientTest do
  use ExUnit.Case, async: true

  @client Path.expand("../../priv/static/voice_converse_client.js", __DIR__)

  test "uncertain delivery can be cleared and confirmed cards disappear" do
    script = ~S'''
    import assert from 'node:assert/strict';
    import { readFileSync } from 'node:fs';
    const source = readFileSync(process.argv[1], 'utf8');
    const { VoiceConverseClient } = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
    class Element {
      constructor() { this.children = []; this.handlers = {}; this.removed = false; }
      append(...items) { this.children.push(...items); }
      addEventListener(name, callback) { this.handlers[name] = callback; }
      remove() { this.removed = true; }
    }
    globalThis.document = { createElement: () => new Element() };
    const container = new Element();
    const sent = [];
    const client = new VoiceConverseClient({ url: '', target: {}, draftContainer: container });
    client.send = frame => sent.push(frame);
    client.renderDraft({ draft_id: 'unknown', status: 'unknown', text: 'Why?' });
    const uncertain = container.children[0];
    assert.equal(uncertain.children.length, 2);
    assert.match(uncertain.children[0].textContent, /delivery is uncertain/);
    assert.equal(uncertain.children[1].textContent, 'Clear');
    uncertain.children[1].handlers.click();
    assert.deepEqual(sent, [{ type: 'discard_draft', draft_id: 'unknown' }]);
    client.renderDraft({ draft_id: 'confirmed', status: 'proposed', text: 'Why?' });
    const proposed = container.children[1];
    client.updateDraft({ draft_id: 'confirmed', status: 'confirmed' });
    assert.equal(proposed.removed, true);
    assert.equal(client.drafts.has('confirmed'), false);
    '''

    assert {"", 0} = System.cmd("node", ["--input-type=module", "-e", script, @client], stderr_to_stdout: true)
  end
end
