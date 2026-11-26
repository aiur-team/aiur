# MP-N4 — Post-refactor plan refresh

## 12. Daemon push-relay starting point

Refresh SHA: `1080f8a109ca6c2aaff3259e83c5600e9abb36ef` (2026-10-27).
This checkout contained `chunks.md` and tickets, but no MP-N4 `plan.md`.
This section supplies the requested refresh; it does not reconstruct §§1–11.
Historical `base_sha: 45a290e3` metadata remains unchanged.

### Package and path mapping

MP-R1 uses manifest ownership within the existing application, not a directory
move for every component. `components/push-relay.json` is planned, layer 3,
optional, with `paths: []`: there is no landed push package source directory.
All `src/lib/aiur/push/**` paths below are **PROPOSED**, owned by `push-relay`;
register them in that manifest when implementing. The old proposed path is
retained because it has not moved. Tests under `src/test/aiur/push/**` are also
PROPOSED. The relay service is a separate component and deployment.

Paths in this table are relative to `src/lib/aiur/` unless stated otherwise.
“Old” refers to the pre-refactor ticket citations, not callable APIs today.

| Old citation | Current location / public entry | Owner and consumer |
| --- | --- | --- |
| `decision_store.ex:154,190,388,393` | `decision_store.ex:70,377`; public `commands.ex:183` (`Aiur.Commands.list_decisions/0`) | commands; C3-T02/N5 reconciliation; Store is private |
| `events/exchange.ex:70`, `events/publisher.ex:57,113` | Same implementation paths (`:70`, `:109`); public `events.ex:13,20,23` (`Aiur.Events`) | event-bus; N5 Source; Exchange/Publisher are private |
| `config/paths.ex:243` | `config/paths.ex:329`, `Aiur.Config.Paths.runtime_state_dir/0` | config source; launcher owns the runtime directory; C3-T02; CR-N4-PATH-1 |
| `http_server.ex:143` | `http_server.ex:266`, `Aiur.HttpServer.base_url/0` | web-shell; no N4 import (reachability belongs to N2) |
| `Aiur.AgentControlCli.status/1`, `agent_control_cli.ex:100` | `Aiur.AgentControlCLI.status/1`, `agent_control_cli.ex:9` delegates to `orchestrator/status_cli.ex:31` | control-cli → orchestration; C3-T07 |
| `print_status_report/3`, `agent_control_cli.ex:189` | `orchestrator/status_cli.ex:104` (private renderer) | orchestration; C3-T07 edits renderer within its owner |
| `aiur-engine.sh:2612,4110` | `packaging/npm/aiur-cli/libexec/engine/commands.sh:40,45`; dispatch in `libexec/aiur-engine.sh:272` | launcher; C3-T07 |
| `workflow.ex:85-94` | `workflow.ex:86-96`, `Aiur.Workflow.resolve_config_path/1` | config; historical workflow precedent only, C3-T01 |
| `init/alerts.ex:19-20` | Same path and range | init; historical machine-file precedent only, C3-T01 |
| `decision.ex:18-42,120-136` | `decision.ex:170-204` enforced keys and struct | commands; C1-T03 payload fields |
| `src/lib/aiur.ex:244-251` child placement | `src/lib/aiur.ex:190` delegates to `application/children.ex:31` | control-cli composition root; C3-T04 |
| `src/lib/aiur_web/github_webhook/signature.ex:33` | Same path and line | github-listeners; C1-T01 crypto precedent, no import |
| `src/lib/aiur_web/financial_data_access/proof.ex:156` | Same path and line | dashboard-ui; C1-T01 crypto precedent, no import |
| `push/**` | Same PROPOSED `src/lib/aiur/push/**`; `Aiur.Push.*` | push-relay; C1-T01..T04 and C3-T01..T07 |

### Retained feed and persistence

MP-R2-C6 is landed at the refresh SHA: `events/durable_consumer.ex`,
`events/durable_consumer/source.ex`, `events/durable_consumer/export_source.ex`,
`events/export.ex`, and `events/journal.ex` exist. N5 can use the public
`Aiur.Events.DurableConsumer.ExportSource` with dense `seq` cursors; event IDs
remain dedupe identities. Live subscription is only the explicit fallback when
export is unavailable, not a claim that C6 is still missing. Runtime availability
still depends on exporter configuration and capability state.

`Aiur.Events.Journal` is a public bus facade backed by `Aiur.Journal` (kernel).
Its replay rejects corrupt records; it is not automatically interchangeable with
C3-T02's torn-tail policy. Direct `Aiur.Journal` reuse needs CR-N4-PATH-1.
The DecisionStore is persistence precedent only; reconcile via `Aiur.Commands`.

### Planned imports and rule audit

The shipped push manifest requires identity, pairing-discovery, event-bus and
commands; optional edges are build-orders **and build-queue**. No source or
manifest is changed by this refresh. C3-T03's `Aiur.Machine.Store.sign(:push, bytes)`
is still PROPOSED under pairing-discovery (MP-N2); the permissive placeholder
facade cannot prove that API exists. Req, OTP and crypto calls are external to
these internal reference rules.

Run from the repository root with the following command (the audit body follows):

```sh
python3 - <<'PYTHON'
from pathlib import Path
plan = Path('docs/research/aiur-mobile-and-platform/bucket-3-mobile-watch/MP-N4/plan.md')
exec(plan.read_text().split(chr(96) * 3 + 'python\n')[1].split(chr(96) * 3)[0])
PYTHON
```

This calls the dependency checker's actual four-rule evaluator against the
planned imports; it does not pretend the source walker scans unimplemented code.

```python
import json
import sys
from pathlib import Path
sys.path.insert(0, 'scripts')
from components.reference_rules import edge_rules
components = {p.stem: json.loads(p.read_text()) for p in Path('components').glob('*.json')}
push = components['push-relay']
cases = [
    ('commands', 'Aiur.Commands', []),
    ('event-bus', 'Aiur.Events', []),
    ('event-bus', 'Aiur.Events.Journal', []),
    ('event-bus', 'Aiur.Events.DurableConsumer.ExportSource', []),
    ('pairing-discovery', 'Aiur.Machine.Store', []),
    ('commands', 'Aiur.DecisionStore', ['R-private']),
    ('event-bus', 'Aiur.Events.Exchange', ['R-private']),
    ('event-bus', 'Aiur.Events.Publisher', ['R-private']),
    ('config', 'Aiur.Config.Paths', ['R-declared']),
    ('kernel', 'Aiur.Journal', ['R-declared']),
]
for owner, module, expected in cases:
    actual = edge_rules(push, components[owner], module)
    assert actual == expected, (module, actual, expected)
    print(module + ': ' + (', '.join(actual) or 'PASS'))
```

Result: five permitted edge checks pass; three private implementation references
are rejected; config and kernel imports each fail `R-declared`. Neither rejected
import is approved by this document. See [the contract request](CONTRACT-REQUESTS.md).
C3-T02 must stop at those integration points until MP-R1 resolves the request;
C3-T03's registry/signing API remains subject to MP-N2 delivery. A passing rule
check for a prospective module is not an implementation or availability check.
