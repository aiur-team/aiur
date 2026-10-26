# Five wave-2 citation spot checks

Target: `4fbe109541ba1e279d3eb315d8455c4d139c92ba`; these are C1-T01 production starting points, not only existence checks.

| Path | Range | Verified meaning |
| --- | --- | --- |
| `src/lib/aiur/decision.ex` | 152–192 | schema version 1, ticket enforce keys and struct |
| `src/lib/aiur/decision_event/codec.ex` | 13–45 | requested-event normalization and snapshot identity checks |
| `src/lib/aiur/decision_projection.ex` | 43–80 | request snapshot validation and content hash comparison |
| `src/lib/aiur/decision_store/requests.ex` | 159–177 | serialized request handling owner |
| `src/lib/aiur/decision_store/persistence.ex` | 30–68 | requested append before projection repair/notification |

Reproduce each with `git -C "$AIUR_AGENT_WORKSPACE" show 4fbe109541ba1e279d3eb315d8455c4d139c92ba:<path> | sed -n "<start>,<end>p"`. The paths/ranges above were read during the refresh; raw report OK rows alone were not treated as semantic proof.
