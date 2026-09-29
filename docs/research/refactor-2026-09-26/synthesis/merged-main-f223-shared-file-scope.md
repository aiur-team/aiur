# Shared-file citation scope on merged main

The 216-feature delta flags any feature citing a changed path. That intentionally over-queues shared files: 43 entries cite `packaging/npm/aiur-cli/libexec/aiur-engine.sh` and 24 cite `src/lib/aiur/agent_control_cli.ex`. These are 67 cited-path hits, not necessarily 67 changed behaviors. This note compares exact hunks from frozen `3339b887` to merged `f223f30e`; indirect call effects still need tests.

| Shared path | Exact merged-main hunk scope | Directly relevant feature IDs |
| --- | --- | --- |
| `aiur-engine.sh` | Remove guard help and dispatch; pass `AIUR_LAUNCHER_PID` only to fresh foreground BEAM and unset it in detached mode; record/resolve instance-owned agent pidfile for `stop`; correct a reap comment. Other command handlers have no edited lines. | `cli-01`, `cli-02`, `cli-16`, `cli-38`, `subsystems-21`, `subsystems-30`, `ui-32`; `cli-17` calls run/start after restart and needs an indirect check. |
| `agent_control_cli.ex` | Move `usage/2` provider meter rendering to new `Aiur.ProviderMeters.CLI`, with `usage_bar/1` delegated. Its other command handlers have no edited lines in this diff. | `cli-10` and status/usage consumers of the extracted presenter; check unknown, age, reset and model labels. |

The remaining source-path hits in these two files mostly reflect coarse whole-file citations, not an edited command-specific hunk. This narrows the first inspection pass, but does not mark the other feature decisions current or safe: shared session startup can affect every command launched through the engine, and an extracted presenter can alter output despite an unchanged caller. Verify indirect behavior through the real CLI and packaged release where relevant.
