# Codex event path mirrors at `b4bc11ffc`

This is a static simplification boundary for
`src/lib/aiur/codex/event_humanizer.ex` at
`b4bc11ffcb6abf693bb3c8570aca3e12d82cb24f`. It is not a runtime
incidence claim or an implementation approval.

## What the helpers actually do

[`map_path/2`](../../src/lib/aiur/event_humanizer_helpers.ex) (lines 5–13,
91–114) traverses each map segment with `Map.fetch` on the requested key,
then tries the existing atom or string counterpart **only when that key is
absent**. Thus one string-key path already reads an all-atom map and a map
whose levels mix string and atom keys. A present `nil` or `false` wins the
segment lookup and stops that path; the surrounding `||` or
`Enum.find_value` can then try the mirrored all-atom path. The mirror can
read a different value where both key forms coexist.

Direct helper probes using `elixir -r
src/lib/aiur/event_humanizer_helpers.ex -e '…'` at this SHA produced:

| Map shape | String path | Atom path |
| --- | --- | --- |
| `%{params: %{msg: %{text: "atom only"}}}` | `"atom only"` | `"atom only"` |
| `%{"params" => %{"msg" => %{"text" => nil, :text => "atom leaf"}}}` | `nil` | `"atom leaf"` |
| `%{"params" => %{"delta" => false, :delta => "atom fallback"}}` | `false` | `"atom fallback"` |
| `%{:params => %{:msg => %{:text => "atom"}}, "params" => %{"msg" => %{"text" => nil}}}` | `nil` | `"atom"` |

These are semantic differences, not merely duplicate source lines. For
example, `delta_paths/0` (lines 322–359) uses `Enum.find_value` (lines
318–320): if the first string path returns `false`, its atom mirror may
produce the preview before a later field is considered. Direct `||` chains
such as `turn/completed` (lines 21–32), `item/tool/requestUserInput` (lines
131–136), and wrapper command selection (lines 422–438) have the same
ordering issue. Their fallbacks and formatting also differ, so a generic
reordering of fields is outside this first edit.

[`map_value/2`](../../src/lib/aiur/event_humanizer_helpers.ex) (lines 16–20)
is different: it tries only exact keys supplied to `Enum.find_value`. An
atom-only `%{type: "reasoning"}` returns `nil` for `["type"]` and
`"reasoning"` for `["type", :type]`. Its paired keys in item, command and
rate-limit extraction (humanizer lines 197–199, 247–248, 280–298) cannot be
deleted under the `map_path/2` argument.

## Smallest deletion contract

Start with the `thread/started` ID lookup at humanizer lines 11–13: replace
its two `map_path` calls with the string path only **after** establishing a
collision-free payload contract for that entry point. The sufficient
invariant is that no traversed map has both the string and atom form of a
requested key; string-only, atom-only and mixed-per-level maps all qualify.
The live app-server receive path uses `Jason.decode` on port bytes
([`turn_loop.ex`](../../src/lib/aiur/app_server/turn_loop.ex), lines 57–71),
and the control CLI later passes the stored update payload to this humanizer
([`token_accounting.ex`](../../src/lib/aiur/orchestrator/token_accounting.ex),
lines 205–210;
[`agent_control_cli.ex`](../../src/lib/aiur/agent_control_cli.ex), lines
2624–2660). That supports a string-key live path. It does not prove the
public humanizer accepts only decoded JSON: the CLI tests also inject
in-memory activity maps (`agent_control_cli_test.exs`, lines 3447–3508).

Under unrestricted map input, **no mirrored `map_path` call is proved
behavior-preserving to delete**. The minimal first implementation must
either enforce/document the collision-free contract at the boundary or
retain collision behavior with a purpose-built lookup. Require a focused
test matrix for string-only, atom-only, mixed-per-level, present-`nil`,
present-`false`, and parent/leaf dual-key collisions; the intentional
outcome for collisions must be explicit. Only then apply the same proof to
the larger `delta_paths`, `token_usage_paths` and `reasoning_focus_paths`
lists (humanizer lines 322–359, 471–508). Keep every logical field's current
priority order and all `map_value` aliases.
