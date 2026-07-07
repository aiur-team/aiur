# T-020: Shared atomic-write + JSONL-decode helpers

**Phase:** 2
**Depends-on:** None
**Labels:** `agent:todo` `refactor` `phase:2` `complexity:2`

## Problem / context

The "write sibling temp file, rename into place" pattern is hand-rolled three times in Elixir with divergent tmp-naming and durability choices (`docs/refactor/research-arch/dup-infra.md` §11): `src/lib/aiur/json_store.ex:31-50` (`write!/2`, unique tmp suffix + fsync), `src/lib/aiur/shutdown.ex:87-98` (`atomic_write/2`, **fixed** `.tmp` sibling — concurrent writers would clobber each other's staging file, exactly the bug JsonStore's unique-suffix comment warns about), and `src/lib/aiur/claude/remote_control.ex:103-114` (`write_atomic/2`, unique suffix, no fsync). Separately, "Jason-decode a log/transcript line, skip if malformed" is re-invented as private one-off wrappers (dup-infra §14) in `src/lib/aiur/claude/remote_control.ex:220-225`, `src/lib/aiur/claude/transcript_tailer.ex:203-208`, `src/lib/aiur/alert_feed.ex:103-111`, and `src/lib/aiur/agent_log.ex:59-68`.

This ticket creates two shared helpers — `Aiur.Fs.atomic_write/3` and `Aiur.Jsonl` (`decode_line/1`, `stream/1`), the exact names pinned by dup-infra §11/§14 — and migrates the sites above onto them. **Failure semantics are frozen:** every caller must behave byte-for-byte the same on decode error and on partial/failed write as it does today (readers see old-or-new file contents, never a prefix; malformed lines are dropped/`:error`/`nil` exactly as each caller does now). `src/lib/aiur/session_handle.ex` is an unchanged consumer of `JsonStore` (FI-ART-017) — read it for context, do not edit it.

## Scope (exact)

1. **Create `src/lib/aiur/fs.ex`** with exactly this content (adjust nothing but the moduledoc wording if `mix format` requires):

   ```elixir
   defmodule Aiur.Fs do
     @moduledoc """
     Shared filesystem primitives.

     `atomic_write/3` writes to a uniquely-suffixed sibling temp file and
     renames it into place, so any concurrent reader sees either the previous
     contents or the complete new contents — never a prefix. rename(2) within
     a directory is atomic on POSIX; last-writer-wins for the target path.
     Pass `fsync: true` when the data must be on disk before the rename is
     observable (crash-safe persistence, see `Aiur.JsonStore`).

     Does not create parent directories — callers that need that (JsonStore)
     mkdir_p themselves. The staged temp file is removed on any failure.
     """

     @spec atomic_write(Path.t(), iodata(), keyword()) :: :ok | {:error, term()}
     def atomic_write(path, contents, opts \\ []) when is_binary(path) do
       tmp = path <> ".tmp." <> Integer.to_string(System.unique_integer([:positive]))

       result =
         if Keyword.get(opts, :fsync, false) do
           write_with_fsync(tmp, contents)
         else
           File.write(tmp, contents)
         end

       case result do
         :ok -> rename_or_cleanup(tmp, path)
         {:error, reason} -> cleanup_error(tmp, reason)
       end
     end

     defp rename_or_cleanup(tmp, path) do
       case File.rename(tmp, path) do
         :ok -> :ok
         {:error, reason} -> cleanup_error(tmp, reason)
       end
     end

     defp cleanup_error(tmp, reason) do
       _ = File.rm(tmp)
       {:error, reason}
     end

     defp write_with_fsync(tmp, contents) do
       with {:ok, fd} <- :file.open(tmp, [:write, :binary, :raw]) do
         try do
           with :ok <- :file.write(fd, contents) do
             :file.sync(fd)
           end
         after
           :ok = :file.close(fd)
         end
       end
     end
   end
   ```

2. **Create `src/lib/aiur/jsonl.ex`** with exactly this content:

   ```elixir
   defmodule Aiur.Jsonl do
     @moduledoc """
     Decode-or-skip helpers for line-oriented JSON (JSONL / ndjson) logs and
     transcripts. `decode_line/1` accepts only JSON objects — a malformed line
     or a non-object JSON value is `:skip`, never a raise. Callers that need a
     different malformed-line policy keep a one-line adapter over this module.
     """

     @spec decode_line(binary()) :: {:ok, map()} | :skip
     def decode_line(line) when is_binary(line) do
       case line |> String.trim() |> Jason.decode() do
         {:ok, record} when is_map(record) -> {:ok, record}
         _ -> :skip
       end
     end

     @spec stream(Path.t()) :: Enumerable.t()
     def stream(path) when is_binary(path) do
       path
       |> File.stream!(:line)
       |> Stream.flat_map(fn line ->
         case decode_line(line) do
           {:ok, record} -> [record]
           :skip -> []
         end
       end)
     end
   end
   ```

3. **Migrate `src/lib/aiur/json_store.ex`** (currently 73 lines): add `alias Aiur.Fs` under the existing `require Logger`; replace the body of `write!/2` (lines 31-50) with:

   ```elixir
   def write!(path, term) when is_binary(path) do
     File.mkdir_p!(Path.dirname(path))
     :ok = Fs.atomic_write(path, Jason.encode!(term), fsync: true)
     :ok
   end
   ```

   Keep the `@doc`/`@spec` and the moduledoc; you may move the "unique tmp suffix" comment into `Aiur.Fs` (step 1 already carries it) and delete it here. `write!/2` must still raise on any failure (the `:ok =` match does this). **Do not touch `read/2` (lines 57-72)** — its `{:error, reason}` corruption contract is load-bearing (FI-ART-013).

4. **Migrate `src/lib/aiur/shutdown.ex`** (currently 165 lines): add `Aiur.Fs` to the alias block (insert `alias Aiur.Fs` after `alias Aiur.Config` at line 26, alphabetical); change the call at line 65 from `atomic_write(path, Config.workspace_root())` to `Fs.atomic_write(path, Config.workspace_root())`; delete the private `atomic_write/2` (lines 84-98, including its comment block — the guarantee now lives in `Aiur.Fs`). The caller's `case ... do :ok -> ...; {:error, reason} -> Logger.warning(...)` handling is unchanged. Note this upgrades the fixed `.tmp` name to a unique suffix — that is the point; the reader-facing contract (old-or-new, never a prefix, `{:error, reason}` on failure) is identical.

5. **Migrate `src/lib/aiur/claude/remote_control.ex`** (currently 528 lines): add `alias Aiur.Fs` and `alias Aiur.Jsonl` under `require Logger` (line 29); change line 82 from `write_atomic(path, Jason.encode!(updated))` to `Fs.atomic_write(path, Jason.encode!(updated))`; delete the private `write_atomic/2` (lines 103-114). Replace the body of `decode_transcript_record/1` (lines 220-225) with:

   ```elixir
   defp decode_transcript_record(line) do
     case Jsonl.decode_line(line) do
       {:ok, record} -> [record]
       :skip -> []
     end
   end
   ```

   **Do not touch `decode_config/1` (lines 95-101)** — it is whole-file config decode with a preserved error reason, not a JSONL site.

6. **Migrate `src/lib/aiur/claude/transcript_tailer.ex`**: add `alias Aiur.Jsonl` after the existing `alias Aiur.Claude.Transcript` (line 26). Replace the body of the private `decode/1` (lines 203-208) with:

   ```elixir
   defp decode(line) do
     case Jsonl.decode_line(line) do
       {:ok, record} -> {:ok, record}
       :skip -> :error
     end
   end
   ```

7. **Migrate `src/lib/aiur/alert_feed.ex`**: add `alias Aiur.Jsonl` to the alias block (after `alias Aiur.Config.Paths`, line 7). Replace the pipeline in `read_alerts/1` (lines 90-101) with:

   ```elixir
   defp read_alerts(path) do
     agent = agent_from_path(path)

     path
     |> Jsonl.stream()
     |> Stream.filter(&(Map.get(&1, "event") == "alert"))
     |> Enum.map(&normalize_alert(&1, agent))
   rescue
     _ -> []
   end
   ```

   Delete the private `decode_line/1` (lines 103-111). The existing `rescue -> []` stays and preserves today's behavior for missing/unreadable files (`File.stream!` raises lazily inside the rescue, exactly as before); malformed lines are dropped exactly as the old `Stream.reject(&is_nil/1)` did.

8. **Migrate `src/lib/aiur/agent_log.ex`**: add `alias Aiur.Jsonl` directly under `defmodule Aiur.AgentLog do` (line 1; it has no alias block). In `parse_log_entry/3` (lines 59-68), change the `with` clause `{:ok, payload} <- Jason.decode(trimmed_body)` (line 63) to `{:ok, payload} <- Jsonl.decode_line(trimmed_body)`. Keep the `"{" <> _ <- trimmed_body` prefix guard — with it, every valid decode is an object, so the map-only filter changes nothing.

9. **Create `src/test/aiur/fs_test.exs`** — `defmodule Aiur.FsTest`, `use ExUnit.Case, async: true`, `@moduletag :tmp_dir`. Test cases (all against `Aiur.Fs.atomic_write/3`):
   - writes contents readable at `path` and returns `:ok`;
   - overwrites an existing file's previous contents;
   - `fsync: true` writes identical contents and returns `:ok`;
   - after a successful write, no `<basename>.tmp.*` sibling remains in the directory (`Path.wildcard(path <> ".tmp.*") == []`);
   - returns `{:error, :enoent}` when the parent directory does not exist, and leaves no temp file behind;
   - two sequential writes to the same path both succeed and the file holds the second contents.

10. **Create `src/test/aiur/jsonl_test.exs`** — `defmodule Aiur.JsonlTest`, `use ExUnit.Case, async: true`, `@moduletag :tmp_dir`. Test cases:
    - `decode_line/1` on a JSON object line returns `{:ok, map}`;
    - `decode_line/1` tolerates surrounding whitespace and a trailing newline;
    - `decode_line/1` on malformed JSON returns `:skip`;
    - `decode_line/1` on valid non-object JSON (`"[1,2]"`, `"42"`) returns `:skip`;
    - `stream/1` over a fixture file containing valid-object, malformed, and non-object lines yields only the decoded maps, in file order.

11. Run the Agent gate (below). Every pre-existing test file named in **Files → Test** must pass **without any modification**.

## Files

- Create: `src/lib/aiur/fs.ex`, `src/lib/aiur/jsonl.ex`, `src/test/aiur/fs_test.exs`, `src/test/aiur/jsonl_test.exs`
- Modify: `src/lib/aiur/json_store.ex`, `src/lib/aiur/shutdown.ex`, `src/lib/aiur/claude/remote_control.ex`, `src/lib/aiur/claude/transcript_tailer.ex`, `src/lib/aiur/alert_feed.ex`, `src/lib/aiur/agent_log.ex`
- Test (must pass unmodified): `src/test/aiur/json_store_test.exs`, `src/test/aiur/shutdown_test.exs`, `src/test/aiur/claude/remote_control_test.exs`, `src/test/aiur/claude/transcript_tailer_test.exs`, `src/test/aiur/alert_feed_test.exs`, `src/test/aiur/agent_log_test.exs`, `src/test/aiur/session_handle_test.exs`

## Out of scope

- `src/lib/aiur/agent_skills.ex` `stage_and_rename/2` (directory-shaped atomic-rename variant; dup-infra §11 leaves it) — do not touch.
- The shell analogue `write_aiur_instance_record` in `packaging/npm/aiur-cli/libexec/aiur-engine.sh` (pre/post-BEAM lifecycle; stays shell-side).
- `src/lib/aiur/codex/transcript.ex` `decode_codex_json/1` (lines 207-217): it decodes arbitrary JSON *values* (non-map results pass through; bad JSON wraps as `%{"raw" => str}`, load-bearing per FI-CDX-057). Migrating it onto the map-only `decode_line/1` would change behavior — leave it alone.
- `Aiur.JsonStore.read/2` and `Aiur.Claude.RemoteControl.decode_config/1` — whole-document decodes whose `{:error, reason}` payload is part of the contract.
- `src/lib/aiur/session_handle.ex` and all other `JsonStore` consumers (`events/id_generator.ex`, `events/subscription_store.ex`) — no edits; they inherit the change through `JsonStore.write!/2`.
- Every other dup-infra cluster (§1-§10, §12, §13, §15) — separate tickets.
- No `mkdir_p` inside `Aiur.Fs`; no retry/backoff logic; no changes to any public function signature.

## Inventory-IDs

- **FI-ART-013** — JsonStore crash-safe write pattern (tmp + fsync + rename): `json_store.ex` write path now delegates to `Aiur.Fs`; the tmp+fsync+rename guarantee must survive verbatim.
- **FI-ART-029** — `~/.claude.json` workspace trust pre-seed: `remote_control.ex` atomic read-modify-write; atomicity and shape-preservation are the contract (tmp suffix becomes `.tmp.<unique>` instead of `.aiur-tmp-<unique>`; the name is not load-bearing, the atomicity is).
- **FI-ART-030** — Claude transcript jsonl read-only tail: `transcript_tailer.ex` + `remote_control.ex` transcript reads (malformed lines dropped, read-only).
- **FI-ART-033** — Session-scoped reaper handoff tmpfiles: `shutdown.ex` writes `aiur-<pid>-workspace-root` whole-or-not-at-all for the bash cwd-sweep backstop.
- **FI-ART-018** — Central alerts feed `alerts.ndjson`: `alert_feed.ex` line decoding.
- **FI-ART-019** — Workspace agent transcript sinks: `agent_log.ex` parses agent.md JSON bodies (reader side only; the writer `agent_event_log.ex` is untouched).
- **FI-ART-015 / FI-ART-016 / FI-ART-017** — event-ID counter, subscription state, SessionHandle: unmodified `JsonStore.write!` consumers whose durability rides on this change; their tests are part of the gate.
- **FI-CDX-057** — the reason `codex/transcript.ex` is excluded (see Out of scope).

## Characterization-tests

The entire `src/test/aiur/regression/` suite must pass **UNMODIFIED**. Specifically protecting this ticket's files:

- `src/test/aiur/regression/shutdown_cleanup_test.exs` (existing — Shutdown/reaper handoff paths).
- The regression suites added by Phase-1 tickets **T-009** (engine identity, reap & control RPC — covers `remote_control.ex` reap/handoff surface) and **T-013** (agent_runner drain/resume & digest — covers session resume through `JsonStore`/`SessionHandle`), whatever files those tickets landed under `src/test/aiur/regression/`.

## Acceptance criteria

- `grep -c "defmodule Aiur.Fs do" src/lib/aiur/fs.ex` → `1`; `grep -c "defmodule Aiur.Jsonl do" src/lib/aiur/jsonl.ex` → `1`.
- Each new file ≤ 200 lines (`wc -l src/lib/aiur/fs.ex src/lib/aiur/jsonl.ex`); every function ≤ 20 logic lines.
- `grep -rn "File.rename" src/lib --include='*.ex'` returns exactly **2** hits: one in `src/lib/aiur/fs.ex`, one in `src/lib/aiur/agent_skills.ex` (untouched directory variant). No other module performs its own rename.
- `grep -n "write_atomic\|defp atomic_write" src/lib/aiur/shutdown.ex src/lib/aiur/claude/remote_control.ex` → no output (both private helpers deleted).
- `grep -n "Jason.decode" src/lib/aiur/claude/transcript_tailer.ex src/lib/aiur/alert_feed.ex src/lib/aiur/agent_log.ex` → no output; `grep -c "Jason.decode" src/lib/aiur/claude/remote_control.ex` → `1` (only `decode_config/1` remains).
- Parent files shrank: `wc -l` shows `src/lib/aiur/json_store.ex` < 70 (was 73), `src/lib/aiur/shutdown.ex` < 160 (was 165), `src/lib/aiur/claude/remote_control.ex` < 525 (was 528).
- `src/test/aiur/fs_test.exs` defines `Aiur.FsTest`; `src/test/aiur/jsonl_test.exs` defines `Aiur.JsonlTest`; both run green.
- `grep -n "Aiur.Fs\|Aiur.Jsonl" src/mix.exs` → no output (the new modules are NOT in coverage `ignore_modules` — the 85% threshold enforces their tests).
- `git diff --stat` touches only the ten files listed under **Files** (plus nothing under `src/test/aiur/regression/`).
- All seven pre-existing test files listed under **Files → Test** pass with zero diff to their contents.

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

- **FI-ART-029 spot-check:** confirm `src/test/aiur/claude/remote_control_test.exs` is untouched in the diff and green — it pins that the `~/.claude.json` edit preserves unrelated keys, treats a missing file as `{}`, errors (never clobbers) on unexpected shape, and leaves no temp file.
- **FI-ART-033 spot-check:** `src/test/aiur/shutdown_test.exs` and `src/test/aiur/regression/shutdown_cleanup_test.exs` untouched and green — the `aiur-<pid>-workspace-root` handoff file is still written whole and the launcher-facing error path still only warns.
- **FI-ART-013 spot-check:** `src/test/aiur/json_store_test.exs` untouched and green; verify by inspection that `Aiur.Fs.atomic_write/3` with `fsync: true` still fsyncs *before* rename (the ordering is the durability contract).
- **FI-ART-018/019/030 spot-check:** `alert_feed_test.exs`, `agent_log_test.exs`, `transcript_tailer_test.exs` untouched and green — malformed ndjson/transcript lines are still silently dropped, not raised.
- Diff review: zero changes under `src/test/aiur/regression/`; no new entry in `src/mix.exs` `ignore_modules`; `src/lib/aiur/codex/transcript.ex` and `src/lib/aiur/agent_skills.ex` unmodified.

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
