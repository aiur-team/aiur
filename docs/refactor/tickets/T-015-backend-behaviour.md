# T-015: Formalize Aiur.CodingAgent.Backend behaviour

**Phase:** 2
**Depends-on:** T-014
**Labels:** `agent:todo` `refactor` `phase:2` `complexity:3` `model:claude`

## Problem / context

The backend seam is half-built. `Aiur.CodingAgent.backends/0`
(`src/lib/aiur/coding_agent.ex:69-123`) is already the single source of backend
identity — adapter/transcript modules, `can_interrupt`, `safe_checkpoints`,
`remote_control`, `resumable`, `immediate_delivery`, `models`, `efforts` all
live in one map, and unknown backends fail loud (`fetch_backend!/1`,
`src/lib/aiur/coding_agent.ex:477-486`). But the behaviour contract is informal:
five `@callback`s sit inline in the facade module
(`src/lib/aiur/coding_agent.ex:29-35`), the three adapters declare
`@behaviour Aiur.CodingAgent` with zero `@impl` annotations (so the compiler
verifies nothing), and two backend capabilities are still hard-coded as inline
clauses in `src/lib/aiur/agent_runner.ex`: the claude → claude-repl
remote-control promotion (`remote_session_backend/2`, lines 824-825) and the
claude-repl → headless-claude spawn-failure fallback (`start_agent_session/3`,
lines 1037-1059).

Per `docs/refactor/target-architecture.md` §"The coding-agent backend seam",
this ticket creates the formal `Aiur.CodingAgent.Backend` behaviour, annotates
all three adapters, and moves the two hard-coded capabilities into the registry
as declared data. It does NOT touch `agent_runner.ex` — consuming the declared
capabilities there is T-016. All line numbers below are as of commit
`8712a32f`; T-014 (Aiur.AppServer extraction) may have shifted adapter line
numbers, so locate by function name if a cited range has drifted.

## Scope (exact)

1. Create `src/lib/aiur/coding_agent/backend.ex` with EXACTLY this content
   (run `mix format` after; do not add functions — this module is types +
   callbacks only):

   ```elixir
   defmodule Aiur.CodingAgent.Backend do
     @moduledoc """
     The behaviour every coding-agent backend adapter implements.

     A backend is exactly two things:

       1. one adapter module implementing these callbacks, and
       2. one entry in `Aiur.CodingAgent.backends/0` — the registry, the
          single source of backend identity.

     Adding a backend must require nothing else: no new `case` clause in
     dispatch code, no edits outside the new module and its registry
     entry. Cross-backend variance is either a callback here or a
     declared capability in the registry entry (`t:capabilities/0`).
     Unknown backends fail loud in the registry accessors, never here.

     ## Session contract

     A session is the adapter-owned map returned by `c:start_session/2`
     and threaded through every later callback. `Aiur.AgentRunner`
     additionally tags it with `:backend` (the resolved registry key)
     after start, and reads these adapter-set keys:

       * `:thread_id` — the backend-native session/thread id when known
         (`nil` until the first turn for adapters that learn it late).
       * `:resumed` — `true` only when `c:start_session/2` successfully
         rejoined the thread named by `opts[:resume_thread_id]`.

     ## Resume contract

     Resume is carried by `c:start_session/2`, not a separate callback:
     a backend whose registry entry declares `resumable: true` receives
     `opts[:resume_thread_id]` and must attempt to rejoin that thread,
     setting `resumed: true` on success and degrading silently to a
     clean start (`resumed: false`) on any failure — a resume miss must
     never strand an issue. Non-resumable backends never receive the
     option.

     ## Interrupt policy

     In-turn interruption is in-band: the runner sends
     `{:pause_agent, request_id}` and
     `{:agent_queue_updated, identifier, item_id, deliver_now?}` to the
     process executing `c:run_turn/4`. The registry flags
     `can_interrupt` / `safe_checkpoints` / `immediate_delivery` declare
     how the runner schedules delivery around those messages. The
     optional `c:interrupt/1` callback is the out-of-band variant for
     backends whose live process is cut externally (the persistent REPL:
     Ctrl+C into the pane).
     """

     alias Aiur.CodingAgent

     @typedoc "The adapter-owned session map. See \"Session contract\"."
     @type session :: map()

     @typedoc """
     One registry entry in `Aiur.CodingAgent.backends/0`. Required keys
     exist on every backend; optional keys are declared capabilities:

       * `:immediate_delivery` — operator messages pass straight through
         to the live process instead of holding at a checkpoint.
       * `:remote_transport` — the backend an RC-promoted session
         actually runs on (remote control physically runs on the
         persistent-REPL transport).
       * `:fallback_backend` — the backend a failed spawn degrades to,
         once, so a transport failure never strands an issue.
     """
     @type capabilities :: %{
             required(:adapter) => module(),
             required(:transcript) => module(),
             required(:can_interrupt) => boolean(),
             required(:safe_checkpoints) => [atom()],
             required(:remote_control) => boolean(),
             required(:resumable) => boolean(),
             required(:models) => [String.t()],
             required(:efforts) => [String.t()],
             optional(:immediate_delivery) => boolean(),
             optional(:remote_transport) => CodingAgent.backend(),
             optional(:fallback_backend) => CodingAgent.backend()
           }

     @doc "Start a session in the workspace. See \"Resume contract\"."
     @callback start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}

     @doc """
     Run one prompt turn. `{:paused, map()}` covers quota exhaustion and
     operator pause; the runner treats it as suspend, never failure.
     """
     @callback run_turn(session(), String.t(), map(), keyword()) ::
                 {:ok, map()} | {:paused, map()} | {:error, term()}

     @doc "Tear the session down. Must be idempotent and never raise."
     @callback stop_session(session()) :: :ok

     @doc "Canonicalize a raw backend event map (usage, rate limits)."
     @callback normalize_event(map()) :: map()

     @doc "Deliver an operator message into the live session."
     @callback send_operator_message(session(), CodingAgent.operator_payload()) ::
                 {:ok, request_id :: integer()} | {:error, term()}

     @doc """
     Out-of-band interrupt of the live process (optional; implemented by
     the persistent-REPL adapter, which is cut via Ctrl+C into its pane).
     """
     @callback interrupt(session()) :: :ok | {:error, term()}

     @optional_callbacks interrupt: 1
   end
   ```

2. Modify `src/lib/aiur/coding_agent.ex`:

   a. Delete the five `@callback` definitions (lines 29-35: `start_session/2`,
      `run_turn/4`, `stop_session/1`, `normalize_event/1`,
      `send_operator_message/2`). They now live in `Aiur.CodingAgent.Backend`.
      Do NOT delete the `@type` definitions above them (`backend`,
      `operator_payload`, `safe_checkpoint`, `checkpoint_callback_result`) —
      the adapters' `@spec`s reference `Aiur.CodingAgent.operator_payload()`
      and must keep compiling unchanged.

   b. Change the spec of `backends/0` (line 68) from
      `@spec backends() :: %{backend() => map()}` to:

      ```elixir
      @spec backends() :: %{backend() => Aiur.CodingAgent.Backend.capabilities()}
      ```

   c. In the `"claude"` registry entry, insert directly after the
      `remote_control: true,` line (line 89):

      ```elixir
      # Remote control physically runs on the persistent-REPL transport,
      # so an RC-promoted claude issue dispatches claude-repl (carrying
      # the resolved model). Declared here so dispatch code never
      # hard-codes the swap.
      remote_transport: "claude-repl",
      ```

   d. In the `"claude-repl"` registry entry, insert directly after the
      `remote_control: true,` line (line 112):

      ```elixir
      # A tmux/RC start failure must never strand an issue: a failed
      # claude-repl spawn falls back once to the headless claude
      # backend. Declared here so the fallback never lives in a
      # dispatch `case`.
      fallback_backend: "claude",
      ```

   e. Insert these two accessors directly after `resumable?/1` (after
      line 397), exactly:

      ```elixir
      @doc """
      The transport backend an RC-promoted session actually runs on.
      `"claude"` declares `remote_transport: "claude-repl"`; a backend
      with no declared transport — and any unknown backend — promotes
      to itself (no swap).
      """
      @spec remote_transport(backend()) :: backend()
      def remote_transport(backend) do
        case Map.fetch(backends(), backend) do
          {:ok, entry} -> Map.get(entry, :remote_transport, backend)
          :error -> backend
        end
      end

      @doc """
      The backend a failed spawn falls back to, or `nil` when the
      backend declares no fallback. `"claude-repl"` declares
      `fallback_backend: "claude"`. Unknown backends have no fallback.
      """
      @spec fallback_backend(backend()) :: backend() | nil
      def fallback_backend(backend) do
        case Map.fetch(backends(), backend) do
          {:ok, entry} -> Map.get(entry, :fallback_backend, nil)
          :error -> nil
        end
      end
      ```

      The soft-degrade style (no raise) deliberately mirrors
      `remote_control?/1` / `resumable?/1` — capability queries degrade,
      module-dispatch accessors raise (the FI-CDX-002 asymmetry). Do not
      change `fetch_backend!/1` or any existing accessor.

3. Annotate `src/lib/aiur/codex/coding_agent.ex`:

   a. Line 8: change `@behaviour Aiur.CodingAgent` to
      `@behaviour Aiur.CodingAgent.Backend`.
   b. Add `@impl Aiur.CodingAgent.Backend` on its own line immediately above
      each of these five function definitions (below the `@spec` when one is
      present): `start_session/2` (line 52), `run_turn/4` (line 93),
      `stop_session/1` (line 179), `send_operator_message/2` (line 185 — the
      FIRST clause only; never annotate later clauses of the same function),
      `normalize_event/1` (line 1558).
   c. Do NOT annotate `run/4` (line 37) — it is a convenience wrapper, not a
      callback. `@impl` on a non-callback is a compile error under
      `--warnings-as-errors`.

4. Annotate `src/lib/aiur/claude/coding_agent.ex` the same way:

   a. Line 12: `@behaviour Aiur.CodingAgent` → `@behaviour Aiur.CodingAgent.Backend`.
   b. `@impl Aiur.CodingAgent.Backend` above: `start_session/2` (line 33),
      `run_turn/4` (line 61), `stop_session/1` (line 145),
      `send_operator_message/2` (line 151, first clause only),
      `normalize_event/1` (line 861).

5. Annotate `src/lib/aiur/claude/repl_agent.ex`:

   a. Line 21: `@behaviour Aiur.CodingAgent` → `@behaviour Aiur.CodingAgent.Backend`.
   b. `@impl Aiur.CodingAgent.Backend` above: `start_session/2` (line 108),
      `run_turn/4` (line 475 — above the bodiless head
      `def run_turn(session, prompt, issue, opts \\ [])`, not above the
      clauses), `stop_session/1` (line 333, first clause only),
      `normalize_event/1` (line 447), `send_operator_message/2` (line 1029,
      first clause only), `interrupt/1` (line 1058, first clause only — this
      implements the new optional callback).

6. Append this describe block at the end of
   `src/test/aiur/coding_agent_test.exs` (before the final `end`; the module
   already aliases `Aiur.CodingAgent` as `CodingAgent`):

   ```elixir
   describe "Aiur.CodingAgent.Backend wiring" do
     test "every registry adapter implements the behaviour" do
       for {backend, entry} <- CodingAgent.backends() do
         behaviours =
           entry.adapter.module_info(:attributes)
           |> Keyword.get_values(:behaviour)
           |> List.flatten()

         assert Aiur.CodingAgent.Backend in behaviours,
                "adapter #{inspect(entry.adapter)} for #{inspect(backend)} " <>
                  "must declare @behaviour Aiur.CodingAgent.Backend"
       end
     end

     test "remote_transport/1 returns the declared RC transport" do
       assert CodingAgent.remote_transport("claude") == "claude-repl"
       assert CodingAgent.remote_transport("claude-repl") == "claude-repl"
       assert CodingAgent.remote_transport("codex") == "codex"
       assert CodingAgent.remote_transport("nonexistent") == "nonexistent"
     end

     test "fallback_backend/1 returns the declared spawn-failure fallback" do
       assert CodingAgent.fallback_backend("claude-repl") == "claude"
       assert CodingAgent.fallback_backend("claude") == nil
       assert CodingAgent.fallback_backend("codex") == nil
       assert CodingAgent.fallback_backend("nonexistent") == nil
     end
   end
   ```

7. Run `cd src && mix format` on the touched files, then the full Agent gate.
   If `mix compile --warnings-as-errors` reports a callback implementation
   missing `@impl` that is not in the lists above (possible if T-014 moved or
   split a function), add `@impl Aiur.CodingAgent.Backend` above that
   function's first clause in the same adapter file — never above a private
   function or a non-callback.

## Files

- Create: `src/lib/aiur/coding_agent/backend.ex`
- Modify: `src/lib/aiur/coding_agent.ex`,
  `src/lib/aiur/codex/coding_agent.ex`,
  `src/lib/aiur/claude/coding_agent.ex`,
  `src/lib/aiur/claude/repl_agent.ex`
- Test: `src/test/aiur/coding_agent_test.exs` (append only, per Scope step 6)

## Out of scope

- `src/lib/aiur/agent_runner.ex` — untouched. Migrating
  `remote_session_backend/2`, `start_agent_session/3`'s fallback clause,
  `report_repl_session/3`, and the other residual backend branches onto the
  new declared capabilities is T-016.
- `src/lib/aiur/orchestrator.ex` — its direct `ReplAgent.interrupt/1` call
  sites (lines 6062, 6132) stay as they are.
- The Aiur.AppServer shared adapter core (T-014's output) — do not move,
  merge, or dedupe any adapter logic; this ticket only annotates.
- No new backend implementation, no registry entry additions/removals/renames,
  no changes to existing registry values (`models`, `efforts`,
  `safe_checkpoints`, etc.), no changes to `backend_for/1`/`model_for/1`/
  label-resolution logic.
- No `humanizer:` registry key (the event-humanizer dispatch gap is a separate
  consolidation, dup-backends.md Cluster 11).
- No edits to `src/mix.exs` (in particular `ignore_modules`), no edits to
  anything under `src/test/aiur/regression/`, no deletion of the
  `Aiur.CodingAgent` `@type` definitions.

## Inventory-IDs

From `docs/refactor/feature-inventory/cdx.md` (registry + contract entries this
ticket's files implement):

- FI-CDX-001 (backend registry `backends/0` — gains two declared-capability
  keys and a precise spec; all existing keys/values unchanged)
- FI-CDX-002 (fail-loud vs degrade-soft accessor asymmetry — the two new
  accessors join the degrade-soft side)
- FI-CDX-011 (per-backend effort vocabulary — registry map touched, values
  unchanged)
- FI-CDX-012 (delivery-policy defaults per backend — values unchanged)
- FI-CDX-013 (resumability flags — values unchanged; resume contract now
  documented on the behaviour)
- FI-CDX-014 (behaviour contract + session dispatch — the five callbacks move
  verbatim from `Aiur.CodingAgent` to `Aiur.CodingAgent.Backend`; facade
  dispatch functions unchanged)

From `docs/refactor/feature-inventory/cld.md` (entries citing the touched
registry lines / adapter modules): FI-CLD-026 (claude-repl backend registry
entry), FI-CLD-055 (transcript module registration for both claude backends).

## Characterization-tests

Must pass UNMODIFIED (never edit anything under `src/test/aiur/regression/`):

- `src/test/aiur/regression/event_flow_e2e_test.exs` — exercises the
  transcript/digest flow through `CodingAgent` backend dispatch.
- Every file T-013 added under `src/test/aiur/regression/` (agent_runner
  drain/resume & digest characterization) — the drain/resume paths consume
  `can_interrupt`/`safe_checkpoints`/`immediate_delivery`/`resumable` exactly
  as before this ticket.
- The compile-time path-embedding guard test added by T-006 (the new
  `backend.ex` must not embed any `.aiur/` or bundled path — it embeds none).
- The rest of the existing `src/test/aiur/regression/` suite, unmodified, as
  part of `mix test`.

## Acceptance criteria

All mechanically checkable from the repo root:

- `test -f src/lib/aiur/coding_agent/backend.ex` succeeds;
  `grep -c "defmodule Aiur.CodingAgent.Backend" src/lib/aiur/coding_agent/backend.ex`
  = 1; `wc -l < src/lib/aiur/coding_agent/backend.ex` ≤ 200.
- `grep -c "@callback" src/lib/aiur/coding_agent/backend.ex` = 6 and
  `grep -c "@optional_callbacks interrupt: 1" src/lib/aiur/coding_agent/backend.ex`
  = 1.
- The concern is moved, not copied:
  `grep -c "@callback" src/lib/aiur/coding_agent.ex` = 0.
- `grep -rn "@behaviour Aiur.CodingAgent$" src/lib/` returns nothing;
  `grep -c "@behaviour Aiur.CodingAgent.Backend" <file>` = 1 for each of
  `src/lib/aiur/codex/coding_agent.ex`, `src/lib/aiur/claude/coding_agent.ex`,
  `src/lib/aiur/claude/repl_agent.ex`.
- `grep -c "@impl Aiur.CodingAgent.Backend" src/lib/aiur/codex/coding_agent.ex`
  = 5; same grep = 5 for `src/lib/aiur/claude/coding_agent.ex` and = 6 for
  `src/lib/aiur/claude/repl_agent.ex` (counts may exceed by exactly the number
  of extra callback functions T-014 introduced, never less).
- Declared capabilities exist:
  `grep -c 'remote_transport: "claude-repl"' src/lib/aiur/coding_agent.ex` = 1
  and `grep -c 'fallback_backend: "claude"' src/lib/aiur/coding_agent.ex` = 1;
  `grep -c "def remote_transport(" src/lib/aiur/coding_agent.ex` = 1 and
  `grep -c "def fallback_backend(" src/lib/aiur/coding_agent.ex` = 1.
- Nothing consumes them yet (that is T-016):
  `grep -rn "remote_transport\|fallback_backend" src/lib/aiur/agent_runner.ex`
  returns nothing, and `git diff --name-only` against the base contains exactly
  the six files listed in Files.
- `src/lib/aiur/coding_agent.ex` stays a facade, not a dumping ground:
  `wc -l < src/lib/aiur/coding_agent.ex` ≤ 540 (487 today; the two accessors +
  registry keys are the only growth).
- Fail-loud preserved: `grep -c "fetch_backend!" src/lib/aiur/coding_agent.ex`
  ≥ 5 (definition + the four raising accessors, unchanged).
- Tests for the new surface exist:
  `grep -c 'describe "Aiur.CodingAgent.Backend wiring"' src/test/aiur/coding_agent_test.exs`
  = 1, containing the three tests from Scope step 6; every pre-existing test in
  that file passes unmodified.
- Coverage ratchet respected: `grep -c "Aiur.CodingAgent.Backend" src/mix.exs`
  = 0 (the new module is NOT added to `ignore_modules`; it defines no functions,
  so the 85% threshold is unaffected), and `src/mix.exs` is not in the diff.
- Adding a backend = one module + one registry entry: with this ticket merged,
  no `case`/`if` on backend identity exists in `src/lib/aiur/coding_agent.ex`
  outside `resolve_backend_spec` label parsing —
  `grep -n '"claude-repl"\|"codex"' src/lib/aiur/coding_agent.ex` matches only
  inside `backends/0`, `@backend_aliases`, and doc/comment text.

## Verification

### Agent gate (run all, from src/)
```
mix compile --warnings-as-errors
mix format --check-formatted
mix test
mix credo --strict
mix dialyzer
```

### At-merge (reviewer)

- `gh pr diff --name-only` = exactly the six files in Files (one create, four
  lib modifies, one test modify).
- Registry values unchanged (FI-CDX-012/-013 spot probe):
  `cd src && mix run -e 'true = Aiur.CodingAgent.safe_checkpoints("codex") == [:notification, :tool_result]; true = Aiur.CodingAgent.safe_checkpoints("claude") == [:notification]; true = Aiur.CodingAgent.safe_checkpoints("claude-repl") == []; true = Aiur.CodingAgent.resumable?("codex"); false = Aiur.CodingAgent.resumable?("claude"); true = Aiur.CodingAgent.resumable?("claude-repl"); IO.puts("registry ok")'`
  prints `registry ok`.
- New capability accessors:
  `cd src && mix run -e '"claude-repl" = Aiur.CodingAgent.remote_transport("claude"); "claude" = Aiur.CodingAgent.fallback_backend("claude-repl"); nil = Aiur.CodingAgent.fallback_backend("codex"); IO.puts("caps ok")'`
  prints `caps ok`.
- Contract-area suites green:
  `cd src && mix test test/aiur/coding_agent_test.exs test/aiur/coding_agent_claude_test.exs test/aiur/coding_agent_checkpoint_test.exs test/aiur/agent_runner_test.exs`.
- Behavior spot-check via the phase's own aiur run on `v2`: after merge, the
  fleet dispatches at least one `model:claude`-labeled and one codex-routed
  ticket normally (backend resolution, session start, transcript rendering all
  unchanged — this ticket is annotation + declaration only).

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
