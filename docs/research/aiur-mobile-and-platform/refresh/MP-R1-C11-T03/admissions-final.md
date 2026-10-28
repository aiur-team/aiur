# First-frontier RC-23 resolutions

Target: `4fbe109541ba1e279d3eb315d8455c4d139c92ba`; ledger publication `c96025161f1688888de4159d8c31fb117a989b6a`. Counts use LF bytes plus an unterminated last line.

C1-T01 is admitted as backend-only under the existing DESIGN-E2 header exception, after this refresh PR merges. Its old DECISIONS size-owner label is historical; all existing code targets are now small. Do not restore monolithic code.

| C1-T01 existing edit target | Current lines | Predicted ceiling | Owner outcome |
| --- | --- | --- | --- |
| `src/lib/aiur/decision.ex` | 284 | 500 | no oversized owner needed; delegate new logic to small owner modules |
| `src/lib/aiur/decision_event.ex` | 326 | 500 | no oversized owner needed; delegate new logic to small owner modules |
| `src/lib/aiur/decision_event/codec.ex` | 389 | 500 | no oversized owner needed; delegate new logic to small owner modules |
| `src/lib/aiur/decision_projection.ex` | 477 | 477 | no oversized owner needed; delegate new logic to small owner modules |
| `src/lib/aiur/decision_projection/reducers.ex` | 249 | 500 | no oversized owner needed; delegate new logic to small owner modules |
| `src/lib/aiur/decision_store.ex` | 455 | 455 | no oversized owner needed; delegate new logic to small owner modules |
| `src/lib/aiur/decision_store/requests.ex` | 370 | 500 | no oversized owner needed; delegate new logic to small owner modules |
| `src/lib/aiur/decision_store/persistence.ex` | 247 | 500 | no oversized owner needed; delegate new logic to small owner modules |
| `src/lib/aiur/decision_validation.ex` | 488 | 500 | no oversized owner needed; delegate new logic to small owner modules |
| `src/lib/aiur/decision_expiry.ex` | 180 | 500 | no oversized owner needed; delegate new logic to small owner modules |

New Requester/EventData/Projection modules keep the researched budgets (approximately 60/150/100 lines); each proposed focused event-data, projection and request-attributes test file stays under 200 lines. Those tests live under src/test/aiur/commands and match Mix test discovery. Existing large tests are not growth targets.

C4-T00 and C5-T00 spikes only create findings/fixtures: size_owner n/a, each new file <=500. C5-T00 tracker #4451 is already closed; C4-T00 #4450 is in error, so this refresh does not claim either spike ran.

C2-T05 and C3-T01 were measured as prospective next admissions in the checkpoint inventory; their product/copy gates remain. C2-T05 must compact the configuration reference before adding rows so it remains <=500. Recount actual code and tests before their later admission.
