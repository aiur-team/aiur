# Wave-2 prospective admission inventory

This inventory is not final admission: intended tests, exact moved call sites and predicted final sizes still need author review. The two free spikes create findings/fixture files; no production source edits. Historical size_owner declarations are not copied blindly.

Ledger publication: `c96025161f1688888de4159d8c31fb117a989b6a`; current counts from `4fbe109541ba1e279d3eb315d8455c4d139c92ba`.

| Ticket | Existing edit candidate | Current lines | Historical owner | Constraint |
| --- | --- | --- | --- | --- |
| MP-E2-C4-T00 | new findings/fixtures only | 0 existing | n/a | keep every new file <=500 |
| MP-E2-C5-T00 | new findings/fixtures only | 0 existing | n/a | keep every new file <=500 |
| MP-E2-C1-T01 | `src/lib/aiur/decision.ex` | 284 | not in release ledger | final <=500; split/compact if needed |
| MP-E2-C1-T01 | `src/lib/aiur/decision_event.ex` | 326 | DECISIONS | final <=500; split/compact if needed |
| MP-E2-C1-T01 | `src/lib/aiur/decision_projection.ex` | 477 | DECISIONS | final <=500; split/compact if needed |
| MP-E2-C1-T01 | `src/lib/aiur/decision_store.ex` | 455 | DECISIONS | final <=500; split/compact if needed |
| MP-E2-C1-T01 | `src/lib/aiur/decision_store/persistence.ex` | 247 | not in release ledger | final <=500; split/compact if needed |
| MP-E2-C1-T01 | `src/lib/aiur/decision_store/requests.ex` | 370 | not in release ledger | final <=500; split/compact if needed |
| MP-E2-C1-T01 | `src/lib/aiur/decision_validation.ex` | 488 | not in release ledger | final <=500; split/compact if needed |
| MP-E2-C1-T01 | `src/lib/aiur/decision_expiry.ex` | 180 | not in release ledger | final <=500; split/compact if needed |
| MP-E2-C2-T05 | `src/lib/aiur/config.ex` | 449 | CONFIG | final <=500; split/compact if needed |
| MP-E2-C2-T05 | `src/lib/aiur/config/schema/decisions.ex` | 66 | not in release ledger | final <=500; split/compact if needed |
| MP-E2-C2-T05 | `website/docs-app/reference/configuration.md` | 500 | DOCS | final <=500; split/compact if needed |
| MP-E2-C2-T05 | `.aiur/examples/config.example` | 363 | not in release ledger | final <=500; split/compact if needed |
| MP-E2-C3-T01 | `src/lib/aiur/decision_store/revisions.ex` | 288 | not in release ledger | final <=500; split/compact if needed |
| MP-E2-C3-T01 | `src/lib/aiur/decision_event/validation.ex` | 125 | not in release ledger | final <=500; split/compact if needed |
| MP-E2-C3-T01 | `src/lib/aiur/executor_command_cli.ex` | 414 | not in release ledger | final <=500; split/compact if needed |
