# Duplication Map: Coding-Agent Backends & Support Code

Scope: duplication ACROSS the coding-agent backends (`src/lib/aiur/codex/`, `src/lib/aiur/claude/`, `src/lib/aiur/opencode/`) and their support/config code. Every cluster below is *real* duplication — the same logic maintained in N places where a change must be repeated — verified against the source at commit `8712a32f` (branch `refactor-planning-prompt`). All paths are relative to the repo root `/home/orangekid/github/aiur`.

Quantified headline: **753 of the 992 lines of `Aiur.Claude.CodingAgent` are byte-identical to lines in `Aiur.Codex.CodingAgent`** (difflib matching-block analysis; 20 identical blocks of ≥10 lines totaling 587 lines). That single pair dominates the map; the remaining clusters are smaller but each is a "fix it twice or it drifts" trap, and several have *already drifted*.

---

## Cluster 1 — JSON-RPC app-server adapter core (codex ↔ claude headless)

**Severity: highest. ~750 duplicated lines, with observed security-relevant drift.**

### Paths
- `src/lib/aiur/codex/coding_agent.ex` (1997 lines)
- `src/lib/aiur/claude/coding_agent.ex` (992 lines — the moduledoc itself says "Simplified variant of Codex.CodingAgent")

Byte-identical blocks (claude == codex):

| Concern | claude/coding_agent.ex | codex/coding_agent.ex |
|---|---|---|
| run_turn skeleton (session_started/completed/paused/error logging + emit) | 65–160 | 100–194 |
| bash `-lc` Port.open spawn (scrubbed env, 1MB line mode) | 199–221 | 255–277 |
| `initialize` handshake + `initialized` notification | 229–254 | 324–355 |
| `turn/start` frame + turn-id extraction | 286–313 | 477–500 |
| receive_loop (port eol/noeol/exit + pause_agent + agent_queue_updated clause set) | 332–378 | 529–575 |
| handle_incoming / decoded-incoming dispatch (interrupt-response, operator-response, turn/completed, turn/failed) | 380–437 | 577–638 |
| item/tool/call servicing + result classification | 439–468 | 1109–1139 |
| handle_pending_operator_response | 505–536 | 807–838 |
| maybe_process_safe_checkpoint (`{:deliver_text, ...}` protocol) | 537–561 | 842–866 |
| fail_pending / continue_after_turn_completion / continue_after_turn_interrupted / handle_claimed_operator_response / maybe_finish_after_pending_response / handle_pause_request / handle_operator_queue_update / interrupt_turn | 563–742 | 868–1055 (145-line identical block at claude 584–728 == codex 896–1040) |
| turn_completion_status + safe_invoke_{success,failure}_callback | 743–761 | 1068–1086 |
| normalize_tool_result | 762–769 | 1242–1249 |
| await_response / with_timeout_response / handle_response | 771–813 | 1451–1497 |
| log_non_json_stream_line (identical incl. regex, only "Claude"/"Codex" prefix differs) | 815–829 | 1499–1513 |
| issue_context / issue_identifier | 831–837 | 1515–1521 |
| stop_port scaffold (port_info → unregister → Port.close rescue) | 839–858 | 1523–1551 |
| token_value / parse_token_value | 901–916 | 1656–1671 |
| emit_message envelope (merge metadata + :event + :timestamp) | 918–921 | 1746–1749 |
| default_on_message / tool_call_name / tool_call_arguments | 950–971 | 1767–1788 |

### Shape
Both modules are complete, hand-maintained clients for the *same* JSON-RPC 2.0 stdio app-server protocol: fixed request ids (initialize=1, thread/start=2, turn/start=3), bash `-lc` port spawn with `AgentEnvironment` scrubbing, line reassembly, a receive loop that multiplexes port data with in-band control messages, nested operator-turn accounting (`outstanding_turns` + `pending_operator_requests`), the `{:deliver_text, text, on_success, on_failure}` safe-checkpoint delivery protocol, pause-via-`turn/interrupt`, deliver-now queue-update interrupts, response-await with timeout, ProcessReaper registration, and the on_message envelope. The claude module was created by copying the codex one and deleting the approval/quota machinery; every subsequent protocol fix must be applied twice.

**Observed drift (the cost is already real):**
1. `validate_workspace_cwd` — codex (212–238) canonicalizes via `PathSafety.canonicalize` and rejects `:symlink_escape`; claude (180–196) still has the pre-canonicalization prefix check and **lacks the symlink-escape defense** (FI-CDX-019 notes the codex copy is untested and relies on the claude tests — which test the *weaker* logic).
2. Interrupt-error tolerance — codex (595–613, 1057–1067) treats "no active turn" (-32600) as success (fix for the fresh-agent queue-update crash, FI-CDX-035); claude (398–401) still hard-fails `{:turn_interrupt_failed, error}` on any interrupt error, so the same AgentRunner crash class is still reachable on the claude backend.
3. `send_message` — claude (980–991) adds `"jsonrpc" => "2.0"` and rescues `ArgumentError` centrally; codex (1790–1793) omits the jsonrpc field and instead repeats the rescue at four call sites (send_initialize 349–355, send_thread_init 434–439, send_operator_message 206–208, interrupt_turn 1051–1053).
4. `turn/cancelled` — handled by codex (640–654), absent from claude.
5. Startup-timeout floor — codex waits `max(read_timeout, 30_000)` (1451–1457); claude uses the raw read timeout (771–773), so claude cold starts are more timeout-prone.
6. `maybe_set_usage` — claude (927–948) also lifts `cost_usd` and checks `params`; codex (1755–1765) only lifts top-level `usage`.

### Consolidation
Extract a shared `Aiur.AppServer.Adapter` (or `Aiur.CodingAgent.JsonRpcSession`) module owning: port spawn/teardown scaffold, handshake, request/response await, line reassembly, non-JSON logging, the whole receive loop + control-message handling, operator-request accounting, safe-checkpoint delivery, pause/interrupt state machine, tool-call servicing (`normalize_tool_result`, tool_call_name/arguments), `emit_message`, and `send_message` (with the jsonrpc envelope + central rescue). Parameterize via a small behaviour/config struct per backend:
- `backend_label` ("Codex"/"Claude") for logs, and the metadata pid key (`codex_app_server_pid` / `claude_app_server_pid`) — or unify on one `:app_server_pid` key with a compat alias.
- frame builders: `thread_init_frame` (claude: permissionMode; codex: approvalPolicy/sandbox + resume variant), `turn_start_params` (claude: `maybe_put_model`; codex: approvalPolicy/sandboxPolicy).
- a `handle_backend_method/…` hook for what stays genuinely codex-specific: approval-request family (1087–1449), quota-exhaustion pause + unretryable-error classification (777–807, 1905–1996), thread-idle-as-completion (890–895), remote/SSH spawn + model/effort `--config` splice (278–309), `stop_port` kill-tree ordering (1523–1551), and the multi-path usage/rate-limit normalize_event (see Cluster 3).
- workspace validation becomes ONE shared function (the codex canonicalizing version), fixing drift item 1 for free.
Claude-specific residue is tiny: `maybe_put_model`, permissionMode, and simpler stop_port.

---

## Cluster 2 — Turn-loop control-message vocabulary (pause / queue-update) in four receive loops

### Paths
- `src/lib/aiur/codex/coding_agent.ex:545-570` (receive_loop clauses)
- `src/lib/aiur/claude/coding_agent.ex:348-373` (identical clauses)
- `src/lib/aiur/claude/repl_agent.ex:575-595` (hook-driven loop `await_hook_turn`)
- `src/lib/aiur/claude/repl_agent.ex:894-928` (transcript loop `await_turn`)

### Shape
Four hand-rolled receive loops each re-implement the same in-band control-message grammar: `{:pause_agent, request_id}` when integer; `{:agent_queue_updated, identifier, item_id, true}` (deliver-now) vs `{... , _deliver_now}` (ignore) vs the legacy 3-tuple (ignore); plus own-issue vs other-issue filtering in the app-server pair. The tuple shapes and their ignore/act semantics are protocol between AgentRunner/Orchestrator and every backend — adding a field (as happened when the 3-tuple grew to 4) means editing four pattern sets, and the repl loops additionally duplicate the `{:deliver_text, text, on_success, on_failure} | :noop` claim-callback handling (`deliver_immediate_operator_message`, repl_agent.ex:961-982) that the app-server pair implements as `maybe_process_safe_checkpoint`.

### Consolidation
Collapsing Cluster 1 removes two of the four loops. For the remainder, introduce a tiny shared classifier — e.g. `Aiur.CodingAgent.TurnControl.classify(msg, issue_identifier) :: {:pause, id} | :deliver_now | :ignore | :other` — and have every loop receive-all and dispatch through it, so the tuple grammar and own-issue filtering live in one module (with the one unit test that today doesn't exist for the repl copies). The *reactions* (interrupt vs type-into-pane) stay backend-specific.

---

## Cluster 3 — Usage/token normalization vocabulary (3½ copies)

### Paths
- `src/lib/aiur/claude/coding_agent.ex:867-916` (`normalize_usage` + `token_value` + `parse_token_value`)
- `src/lib/aiur/codex/coding_agent.ex:1632-1696` (`canonicalize_usage` + `token_value` + `parse_token_value` + `has_token_field?`/`token_like_value?` repeating the same key list a third time in the same file)
- `src/lib/aiur/codex/event_humanizer.ex:276-329` (`format_usage_counts` — the same input/output/total key vocabulary again, via `map_value` + `parse_integer`)
- (consumer-side sibling: `Aiur.Claude.ReplAgent.normalize_event/1` delegates to the claude copy, repl_agent.ex:446-450 — correct, not duplication)

### Shape
The token-usage key vocabulary — `input_tokens|prompt_tokens|inputTokens|promptTokens`, `output_tokens|completion_tokens|outputTokens|completionTokens`, `total_tokens|total|totalTokens`, each in atom AND string form, each accepting int-or-numeric-string values — is spelled out in full four times across three modules, together with the identical `token_value/parse_token_value` scanners. A new codex/claude protocol spelling (it has already drifted across codex versions, per FI-CDX-041) must be added in every copy or token accounting silently diverges between the orchestrator status (normalize_event) and the watch CLI (humanizer).

### Consolidation
One `Aiur.TokenUsage` module: `canonicalize(map) :: %{input_tokens, output_tokens, total_tokens} | nil`, `token_field?/1`, `format_counts/1` (the humanizer string). The codex-only *search paths* (`absolute_token_usage` multi-version path list, `turn_completed_usage`, rate-limit recursive search, codex/coding_agent.ex:1592-1744) stay in the codex adapter but end in `TokenUsage.canonicalize/1`. Claude's `normalize_usage` and the humanizer's `format_usage_counts` become one-liners over the same module.

---

## Cluster 4 — Transcript-extraction scaffolding (envelope walkers + atom/string `get`)

### Paths
- `src/lib/aiur/codex/transcript.ex:233-272` (`notification_method`, `notification_item`, `codex_turn_id`, `timestamp_for`, `get/2`)
- `src/lib/aiur/claude/transcript.ex:367-406` (`notification_method`, `notification_item`, `claude_turn_id`, `timestamp_for`, `get/2` — byte-identical except the turn-id key `turnId` vs `turn_id`)
- Same atom/string-tolerant `get/2` helper independently re-implemented: `src/lib/aiur/agent_runner.ex:596-599`, `src/lib/aiur/opencode/event_row.ex:207-213`; a fourth variant (string→atom direction too) exists as `Aiur.EventHumanizerHelpers.fetch_map_key` (`src/lib/aiur/event_humanizer_helpers.ex:91-114`)

### Shape
Both transcript modules parse the identical notification envelope (`message.payload.method`, `message.payload.params.item`, params-level turn id with fallback precedence, `:timestamp` DateTime with utc_now default) and carry the identical two-line atom-or-string `Map.get` tolerance helper with the identical comment. The item→event mapping itself (agentMessage/commandExecution/... vs text/thinking/tool_call/...) is genuinely backend-specific and should NOT be merged; the walker scaffolding is pure copy-paste. The stray `get/2` clones in agent_runner and event_row mean the "tolerate both key types" convention is maintained in ≥5 places.

### Consolidation
A small shared `Aiur.Protocol.MapAccess` (or extend `Aiur.EventHumanizerHelpers`, which already solves the same problem for path walking): `get/2`, `dig/2` (codex/coding_agent.ex:1735-1744 has yet another private `dig`), `notification_method/1`, `notification_item/1`, `params_turn_id(message, key, fallback)`, `message_timestamp/1`. Both Transcript modules, AgentRunner, and EventRow import it; the per-backend item mappers stay put.

---

## Cluster 5 — Config "section accessor" pattern across five backend/tracker config modules

### Paths
- `src/lib/aiur/claude/config.ex:49-66` (`section_value` + `trimmed_section_value`)
- `src/lib/aiur/codex/config.ex:18-24, 122-126` (`section_value` + trim-or-default `command/0`)
- `src/lib/aiur/opencode/config.ex:15-25, 105-115, 144-213` (`section_value` with rescue, `raw_section_value`, repeated trim-or-default / trim-or-nil bodies for command, bridge_host, model_prefix, db_path, prewarm_workspace)
- `src/lib/aiur/linear/config.ex:25-37, 60-64, 96-103` (`section_value`, trim-to-nil `project_slug`, `normalize_secret`)
- `src/lib/aiur/github/config.ex:58-115, 160-164, 200-207` (`section_value`, trim-or-default `label_prefix`, trim-or-nil `bot_account`, `normalize_secret`)

### Shape
Five modules re-implement the same three micro-patterns against `Aiur.Config.settings!()`: (a) `settings!().<section> |> Map.from_struct() |> Map.get(String.to_existing_atom(key))` — five copies, only one of which (opencode) rescues the unknown-atom crash, another live divergence; (b) "binary → trim → default when blank" — ≥8 copies; (c) "binary → trim → nil when blank" (`normalize_secret`/`trimmed_section_value`) — 4 copies. Every new backend config module (the refactor will add at least one) copies the trio again.

### Consolidation
A `Aiur.ConfigSection` helper (functions or a `use` macro taking the settings path): `value(key)`, `string(key, default:)`, `optional_string(key)` (trim-to-nil), `bool/int` variants — with the unknown-key rescue from the opencode copy as standard behavior. The five modules keep their domain functions (`command/0`, `permission_mode/0`, …) as thin declarative wrappers; `validate!` behaviours (`Aiur.AgentConfig`, `Aiur.TrackerConfig`) are already in place and unaffected.

---

## Cluster 6 — `$VAR` env-reference resolution: Schema vs Aiur.Linear.Config (double resolution)

### Paths
- `src/lib/aiur/config/schema.ex:918-982` (`resolve_secret_setting`, `resolve_env_value`, `env_reference_name`, `normalize_secret_value` — runs in `finalize_settings/1` at parse time, schema.ex:834-847)
- `src/lib/aiur/linear/config.ex:66-103` (`resolve_env_value`, `env_reference_name`, `normalize_secret` — near line-for-line identical, incl. the `^[A-Za-z_][A-Za-z0-9_]*$` identifier regex and the missing-var→fallback / empty-var→nil semantics)

### Shape
The `$VAR` secret-resolution grammar (config value wins; `$NAME` resolves the env var; missing var → fallback env (`LINEAR_API_KEY`/`LINEAR_ASSIGNEE`); empty var → nil; blank strings normalize to nil) is implemented twice — and worse, applied twice: `Schema.finalize_settings` already resolves `tracker.linear.api_key`/`assignee` into the settings struct, and `Aiur.Linear.Config.api_key/0` then re-runs the same resolution over the *already-resolved* value it reads back from `settings!()`. The behaviors coincide today only because a resolved secret is no longer `$`-prefixed; any change to the grammar (e.g. `${VAR}` support, FI-CFG-029's `env:` decision) must be mirrored or the two layers disagree — and a resolved secret that legitimately *starts with* `$` would be mangled by the second pass.

### Consolidation
Single `Aiur.Config.EnvRef` module (`resolve(value, fallback_env_var)`, `reference_name/1`, `normalize_secret/1`) used by `Schema.finalize_settings`. `Aiur.Linear.Config.api_key/assignee` then simply read the schema-resolved value (`section_value(...) |> normalize_secret()` at most) — deleting its private resolver entirely and eliminating the double-resolution layer.

---

## Cluster 7 — Codex approval-policy enum validator duplicated

### Paths
- `src/lib/aiur/config.ex:24` (`@valid_codex_approval_policies ~w(untrusted on-failure on-request granular never)`) and `src/lib/aiur/config.ex:405-413` (`validate_codex_approval_policy/1`)
- `src/lib/aiur/codex/config.ex:14-15` (`@valid_approval_policies`, `@default_approval_policy`) and `src/lib/aiur/codex/config.ex:65-86` (`resolve_approval_policy` / public `validate_approval_policy/1`)

### Shape
The exact enum list and the trim-then-membership validation exist in two modules with different error shapes (`{:invalid_codex_approval_policy, value}` tuple vs operator string). `Aiur.Config.codex_runtime_settings/2` — the path every codex session actually takes (codex/coding_agent.ex:357-363) — uses the Config copy, while `Aiur.Codex.Config.validate!`/`approval_policy/0` use the local copy. FI-CFG-060 explicitly flags "a duplicate validator in `Aiur.Codex.Config.validate_approval_policy/1` must stay in sync". If codex adds a policy variant, updating one list but not the other yields a config that passes `validate!` but fails at session start (or vice versa) — a boot-vs-runtime split-brain. Security-relevant: only `"never"` flips `auto_approve_requests`.

### Consolidation
Keep ONE canonical list + validator — natural home is `Aiur.Codex.Config` (it owns codex vocabulary) exposing `validate_approval_policy/1` and `valid_policies/0`; `Aiur.Config.codex_runtime_settings/2` calls it and wraps the result in its `{:error, {:invalid_codex_approval_policy, _}}` tuple. Delete `@valid_codex_approval_policies` from config.ex.

---

## Cluster 8 — Codex default sandbox-policy map duplicated

### Paths
- `src/lib/aiur/config/codex_sandbox_policy.ex:36-45` (`default_policy/1` — the canonical resolver default)
- `src/lib/aiur/codex/config.ex:104-120` (`default_turn_sandbox_policy/1` — the `rescue ArgumentError` fallback in `turn_sandbox_policy/0`, byte-identical map: workspaceWrite, writableRoots [workspace], readOnlyAccess fullAccess, networkAccess false, excludeTmpdirEnvVar/excludeSlashTmp false)

### Shape
The effective sandbox an agent gets when config parsing fails is defined twice. This is the agent's blast-radius contract (FI-CDX-046, FI-CFG-064 both rate it high-risk): if someone tightens or extends the canonical policy (say, `networkAccess` semantics or a new exclude flag) in `CodexSandboxPolicy` but not the codex/config.ex fallback, the *failure path* silently runs agents under a different sandbox than the documented default — precisely the path with the least test coverage.

### Consolidation
Make `Aiur.Config.CodexSandboxPolicy.default_policy/1` public (plus the workspace-root fallback chain) and have `Aiur.Codex.Config.turn_sandbox_policy/1`'s rescue call it. Delete the private copy.

---

## Cluster 9 — `shell_escape` implemented six times, in two dialects

### Paths
- `src/lib/aiur/ssh.ex:97-99` — `'` → `'"'"'`
- `src/lib/aiur/workspace.ex:1173-1175` — `'` → `'"'"'`
- `src/lib/aiur/codex/coding_agent.ex:1553-1555` — `'` → `'"'"'`
- `src/lib/aiur/opencode/protocol.ex:445-451` — `'` → `'"'"'` with a safe-charset fast path (public)
- `src/lib/aiur/agent_environment.ex:120-122` — `'` → `'\''`
- `src/lib/aiur/claude/repl_agent.ex:1172-1174` — `'` → `'\''`

### Shape
Six private copies of the security-critical single-quote shell-escape primitive, in two textual dialects (both are valid POSIX quote-splicing, but reviewers must re-verify each). These guard command splice points across all three backends: codex `--config model=…` splice and remote SSH launch, the claude REPL flag builder (`--remote-control`, `--resume`, `--model`…), opencode serve/attach commands, workspace hooks, and env exports. A hardening fix (e.g. rejecting NUL bytes, which single-quoting does NOT neutralize for `bash -lc` argv) would need six edits today.

### Consolidation
One `Aiur.Shell.escape/1` (single canonical dialect; optionally `escape/2` with a `:fast_path` charset option to preserve opencode's readable output). All six call sites switch; opencode/protocol.ex re-exports or callers migrate. Cheap, mechanical, and it turns "is this splice safe?" into a one-module audit.

---

## Cluster 10 — Identifier/filesystem sanitization regex, five copies

### Paths
- `src/lib/aiur/config/paths.ex:61-64` (`sanitize/1`, `[^A-Za-z0-9._-]` → `_` — the documented canonical one, FI-CFG-100)
- `src/lib/aiur/workspace.ex:876` (identical regex, `identifier || "issue"` default)
- `src/lib/aiur/opencode/config.ex:139-142` (`safe_identifier/1` — identical body to the workspace copy, feeds opencode model names/session rows)
- `src/lib/aiur/claude/hook_settings.ex:77` (`slug/1` — same class, `[^A-Za-z0-9_.-]`)
- `src/lib/aiur/test_reset.ex:596` (identical regex)

### Shape
The same character-class replacement produces names that function as *join keys across subsystems*: workspace directory names, opencode `issue-<safe_id>` model ids (FI-OC-055), per-issue log/session filenames, hook-settings temp files. Because each copy is private, nothing enforces they stay identical — if one is "improved" (e.g. also collapsing `..`, which paths.ex documents as a known gap) the joins silently break: a workspace dir sanitized one way and a session file sanitized another no longer pair up for the same identifier.

### Consolidation
`Aiur.Config.Paths.sanitize/1` is already the documented canonical implementation; add `sanitize(value, default)` for the `|| "issue"` variants and point workspace.ex, opencode/config.ex (`safe_identifier` becomes a delegate — keep the public name, its callers are many), hook_settings.ex, and test_reset.ex at it. Any future hardening then changes all join keys in lockstep.

---

## Cluster 11 — Event-humanizer pair with no backend dispatch (latent Claude copy)

### Paths
- `src/lib/aiur/codex/event_humanizer.ex:1-566` (live)
- `src/lib/aiur/claude/event_humanizer.ex:1-133` (latent — implements the same `Aiur.EventHumanizer` behaviour, has zero callers)
- `src/lib/aiur/agent_control_cli.ex:5,415` (hard-codes `Aiur.Codex.EventHumanizer` for every backend)
- `src/lib/aiur/coding_agent.ex:69-123` (the backend registry that carries `adapter:`/`transcript:` per backend — but no humanizer entry)

### Shape
This is the partial/incomplete form of duplication: the codebase established a per-backend dispatch pattern (registry → `adapter`, `transcript` modules) but the humanizer dimension never joined it. The Claude humanizer duplicates the *role* (behaviour impl, shared `EventHumanizerHelpers`, overlapping `turn/started|completed|failed` handlers with different payload paths) yet is dead code, while the watch CLI renders claude app-server notifications through the *codex* method table — claude methods fall through to `humanize_method(method, _)` passthrough at codex/event_humanizer.ex:181-187. Maintaining the claude module today buys nothing; deleting it removes a feature the inventory says must be preserved (FI-CLD-025: "flag before removing").

### Consolidation
Add `humanizer:` to each `Aiur.CodingAgent.backends()` entry (codex → Codex.EventHumanizer; claude/claude-repl → Claude.EventHumanizer) plus a `CodingAgent.humanizer_module/1` accessor mirroring `transcript_module/1`, and make `agent_control_cli.ex:415` dispatch on the session's backend. This makes the claude copy live (satisfying the no-feature-removed contract), and the registry becomes the single place a new backend wires ALL three module roles. The method tables themselves are genuinely protocol-specific — do not merge them; shared rendering utilities already live in `Aiur.EventHumanizerHelpers`.

---

## Cluster 12 — Owner-pid-scoped orphan reaping (panes vs RC servers)

### Paths
- `src/lib/aiur/claude/repl_agent.ex:358-443` (`reap_orphaned_panes` / `sweep_own_panes` / `sweep_repl_panes` / `parse_owner_pid` — regex `^aiur-repl-(\d+)-\d+` — / `os_pid_alive?` via `kill -0`)
- `src/lib/aiur/claude/remote_control.ex:301-328, 487-523` (`reap_orphaned_servers` / `maybe_reap_orphan` — regex `^rc-\d+-\d+.*\.debug$`, owner pid parsed from the filename, same `kill -0` liveness probe at remote_control.ex:506)

### Shape
Two implementations of the same crash-recovery pattern: an artifact name embeds the owning BEAM's OS pid (`aiur-repl-<pid>-<n>` tmux windows; `rc-<pid>-<n>.debug` files), boot-time sweep enumerates artifacts, parses the owner pid, probes liveness with `kill -0`, and reaps ONLY artifacts whose owner is dead so side-by-side aiur instances are never touched. The safety invariant ("never touch a live owner's artifacts") is the load-bearing part and is encoded twice with two parsers and two liveness probes; both are called together at orchestrator boot (orchestrator.ex:6735-6736). A bug fix to the liveness probe (e.g. pid-reuse hardening, or the `rescue → true` fail-safe that only the repl copy has, repl_agent.ex:434-435) must be made twice.

### Consolidation
Small shared helper — `Aiur.OrphanSweep` with `owner_pid(name, regex)`, `os_pid_alive?/1` (adopting the repl copy's fail-safe rescue), and a `sweep(list_fun, owner_match_fun, kill_fun)` skeleton. The artifact-specific parts (tmux window listing + `kill_orphan_pane`+`graceful_kill_tree`; debug-file ls + `pkill -f` + file rm) stay in their modules. Also gives `sweep_own_panes` (graceful-shutdown variant) the same primitives for free.

---

## Explicitly examined and NOT reported (superficial similarity only)

- **Session/resume handling** (codex `resume_outcome` + `thread/resume` vs repl `resume_session_id` + `--resume` existence check): the mechanics are genuinely different (RPC round-trip classification vs on-disk transcript check); the shared glue (handle load/save gating, resumable/local-worker gates, resumed?-driven prompt choice) is already centralized in `Aiur.AgentRunner` (agent_runner.ex:827-940) and `Aiur.SessionHandle`. No change must be repeated across backends today.
- **REPL prompt delivery paths** (`submit_prompt`/`poll_paste_landed` repl_agent.ex:742-773 vs `send_prompt`/`confirm_typed`/`poll_echo` repl_agent.ex:777-834): they share `input_echoes?`/`echo_prefix` already, and the remaining difference — never-clear-best-effort vs clear-and-retype-fail-loud — is documented, regression-trapped behavioral difference (FI-CLD-040/041), not drift. Merging them is a correctness risk, not a cleanup.
- **TranscriptTailer vs DisplayTailer**: composition (DisplayTailer wraps an inner TranscriptTailer), not duplication.
- **Backend registry / delivery-policy flags** (`Aiur.CodingAgent`): already the consolidation point (one map, derived dispatch); Cluster 11 extends it rather than fixing duplication in it.
- **Opencode bridge internals** (chat_completions/session_writer/turn_markers): self-contained; their formatting/protocol logic has no second copy in the codex/claude trees.

## Suggested sequencing for the refactor plan

1. Clusters 7, 8, 9, 10 — mechanical, low-risk, high drift-danger; each is a one-module extraction with existing tests to lean on. Do these first to de-risk the tree before the big move.
2. Clusters 3, 4, 5, 6 — shared vocabulary/scaffolding modules; unlock cleaner diffs for the adapter merge.
3. Cluster 12, 11 — small structural fixes (orphan-sweep helper; humanizer registry dispatch).
4. Clusters 1 + 2 — the app-server adapter core extraction, LAST, once the smaller shared modules exist; land it behind the existing coding_agent_checkpoint_test/coding_agent_claude_test fake-app-server harnesses, and use the merge to close the claude-side drift gaps (symlink-escape validation, no-active-turn interrupt tolerance, startup-timeout floor, turn/cancelled) as explicit, tested behavior changes rather than silent side effects.
