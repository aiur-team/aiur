# U1 focused checks at `main@e196b9658`

Observed in a clean, detached worktree at `e196b9658fcd3a6a010908ec0344579c8f51dd2b`. This commit follows the `v0.0.7` release and changes documentation only. No live Aiur daemon, sandbox ticket, production source, or two-instance stop was touched.

## Focused tests

From the worktree's `src/`, the successful command was:

```sh
MIX_DEPS_PATH="$EXISTING_AIUR_DEPS" mise exec -- mix test test/aiur/opencode/chat_completions/operator_identity_test.exs test/aiur/open_ai_compat/command_runner_budget_test.exs test/aiur_engine_stop_pidfile_test.exs
```

`EXISTING_AIUR_DEPS` was the absolute path to the existing checkout's `src/deps` (kept out of the public artifact). Result: **12 tests, 0 failures**. The isolated checkout had no `deps/`; the first attempt without `MIX_DEPS_PATH` stopped before running tests. A local ignored `src/deps` symlink to the existing dependency sources was also needed because a source component reads Heroicons by the literal relative path `deps/heroicons/...`. The tests compiled into the isolated worktree's `src/_build`; no tracked file changed.

These focused tests cover unauthorized coalesced input, cleared sandbox arguments, and instance-specific pidfile selection. The stop test stubs `reap_aiur_agents`, so its passing result does **not** establish that stopping one live instance spares a sibling process. The bridge test's empty-queue assertion does not independently observe a call to the dispatch seam.

## Real bubblewrap process environment

The probe set synthetic values for `GITHUB_TOKEN`, `GH_TOKEN`, and `GITHUB_APP_PRIVATE_KEY` in the invoking process. It started only an isolated `Task.Supervisor`, disabled the GitHub budget for this probe, then called `Aiur.OpenAICompat.CommandRunner.run/3` with the installed `bwrap` executable and a temporary workspace. The exact in-sandbox command was:

```sh
if env | grep -Eq "^(GITHUB_TOKEN|GH_TOKEN|GITHUB_APP_PRIVATE_KEY)="; then echo leaked; exit 19; else echo clean; fi
```

Result: `%{"exit_code" => 0, "output" => "clean\n", "success" => true}`. The temporary workspace was removed. This proves these three synthetic daemon credential names were absent in one actual bubblewrap child environment; it does not prove every possible secret is absent or test an agent turn.

## Remaining U1 witnesses

- Add a direct no-send assertion at the coalesced text plus turn-marker authorization seam if a stronger claim than the existing empty queue is needed. `ChatCompletions.handle_identified/3` authorizes before it routes the shadowed text.
- Run a two-live-instance stop only in fresh Executor-controlled roots with private state/runtime paths; verify the sibling node, tmux socket, and worker PID before and after stopping the target. Do not use `src/test/regression/aiur-shutdown.sh`: its broad cleanup can kill unrelated Aiur or Opencode processes.
- For the P1 packaged Ctrl+C UX witness, run the real foreground TUI from an Executor checkout, queue an operator message during a turn, send `C-c` through an attached wrapper tmux client, and confirm the same pane survives and the queued text is delivered once. `bash scripts/verify-ctrlc-binding.sh` covers the packaged binding only; sending keys directly to an inner pane bypasses that binding.
