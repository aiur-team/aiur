# MIC-003 — CLI remote target: `aiur --instance <name> <cmd>` with a named-instance registry

**Kind:** executable
**Provenance:** planned in plan v1
**Extends:** new (no existing ticket owns a remote CLI target; #5945 AC4 "the engine's control calls send a bearer token" is satisfied here for remote calls)
**Complexity:** 3 — new transport in the shared launcher engine
**Risk:** medium
**Lane:** NUC
**Phase hint:** 1
**Depends on:** none (built against the KTD1 wire contract with a fake server)
**Requirements:** R1, R2, R3, R5, R10
**Researched at:** ab0c21424

Plan context: [plan](../../2026-10-23-001-feat-multi-instance-control-plan.md) (KTD1, KTD7, U3) · [pack index](../README.md)

## Outcome

From any machine, `aiur --instance nuc status` prints the NUC daemon's status and exits with the NUC's exit code; every command without `--instance` is unchanged.

## Context and evidence

- All daemon control commands funnel through `run_control_rpc_dispatch`, which calls `run_release_rpc_with_timeout "$expression"` and then parses `AIUR_CONTROL_RPC_OUTPUT` for markers (`packaging/npm/aiur-cli/libexec/engine/control.sh:331-441`). Swapping that one call swaps the transport for every command.
- Commands that do not use `run_control_rpc` cannot run remotely: `stop`, `restart`, run/`--bg` (`engine/lifecycle.sh:166-500`), `cleanup-stale`, `doctor`, `upgrade`, `pre-pr`, and the local-BEAM commands `init`, `login`, `logout`, `pr`, `findings`, `ask`, `--version` (`aiur-engine.sh:186-224`); `listen` streams (`engine/control.sh:445-464`).
- `bin/aiur.js` treats any first argument starting with `-` as a launch path that needs tmux (`packaging/npm/aiur-cli/bin/aiur.js:220-236`), so `--instance` must be stripped there first.
- Name collision: `~/.aiur/instances/<key>/` already holds per-instance dashboard secrets (`src/lib/aiur/http_server.ex:352-361`); the registry therefore uses `~/.aiur/remote-instances.yaml` (KTD7).

## Scope

- Global flag `--instance <name>` (and `--instance=<name>`) accepted before the command and stripped before every command classifier: `bin/aiur.js` `requiresInteractiveTools` (`packaging/npm/aiur-cli/bin/aiur.js:220-236`), `scripts/aiurdev`'s bare-run and `pure_control_command` checks (`scripts/aiurdev:110-119,376-381`, so no local rebuild happens), and `aiur_engine_main`; sets `AIUR_REMOTE_INSTANCE`.
- `executor-wait`, `executor-claim`, `executor-release`, `executor-fast-forward` with `--instance` require `--as` (otherwise the consumer id would default to the daemon's hostname, `src/lib/aiur/executor/claims.ex:181-188`).
- Registry reader for `~/.aiur/remote-instances.yaml` (`version: 1`, `instances.<name>.url`, `token_file` or `token_env`). Missing file or name: exit 64 naming the file.
- `run_control_rpc_dispatch`: when `AIUR_REMOTE_INSTANCE` is set, skip `resolve_release`/`prepare_distribution` and call `run_remote_rpc_with_timeout "$expression"`, which POSTs KTD1 with `curl`, maps HTTP errors to messages and exit codes (401/403 → 77, 422 → 64, 504 → 124, transport → 69), and sets `AIUR_CONTROL_RPC_OUTPUT` to the response `output`.
- Refuse `--instance` for every non-RPC command before any network call, naming the reason (the full list in Context; R5).
- Timeouts: send `timeout_ms` equal to the engine's existing per-command rpc timeout for that command; `curl --max-time` is `timeout_ms/1000 + 15`. A 504 on a write prints "outcome unknown on <name>" and is never retried.
- Treat `unknown_on_build` (and `option_not_allowed` for an option the client sent on purpose) as "unsupported on <name> (<build>)"; never retry with fewer options.
- Refuse `http://` URLs unless the host is loopback (`127.0.0.0/8`, `::1`, `localhost`). Tailnet hosts use HTTPS through `tailscale serve`.
- The token is passed to `curl` through a header file or stdin, never argv, and never echoed. A `token_file` that is not mode 0600 is refused. Docs: write tokens go in `token_env`, not in a file.
- Agent environments: add `AIUR_TOKEN_*` to the daemon's agent-environment scrub (the same list that removes `GITHUB_TOKEN`/`GH_TOKEN`, #2356), so agents on the Executor machine do not inherit fleet tokens.

## Non-goals

- `--instance all` (MIC-004). Remote executor-wait merging (MIC-006). Registry write helpers.

## Existing owner and reuse target

- Marker parsing and diagnostics stay in `engine/control.sh`.
- Bun launcher harness `packaging/npm/aiur-cli/test/launcher-support.mjs` (`setupRealLauncher`) and the fake-release pattern in `test/launcher-control.test.mjs:18-60`; add a Bun HTTP server fixture returning KTD1 bodies.

## Contract and invariants

Quote KTD1 and KTD7 from the plan verbatim. Local behaviour is byte-identical when `--instance` is absent.

## Refreshable implementation notes

- New: `packaging/npm/aiur-cli/libexec/engine/remote.sh`; source it from `aiur-engine.sh:66-71`.
- Edit: `engine/control.sh` (`run_control_rpc_dispatch`), `aiur-engine.sh` (flag strip before `case`), `bin/aiur.js` (strip flag before `requiresInteractiveTools`), `scripts/aiurdev` (pass-through).
- Registry parsing: the file has exactly the KTD7 shape (a `version` scalar and a two-level `instances.<name>.<field>` map of scalars). Read it with a small `awk` reader and reject any other shape with a message naming the line. No Python dependency.
- Known output differences, documented: commands that run local shell work before the call (`cmd_status` runs the local `aiur-mise-doctor` first, `engine/commands.sh:43`) skip that step in remote mode; wide tables use the default width because `:io.columns()` has no terminal on the daemon side.
- Test: `packaging/npm/aiur-cli/test/launcher-remote.test.mjs`.

## Acceptance and verification

### Acceptance criteria

1. With a fake server returning `"output":"ok\n__AIUR_CONTROL_EXIT__:0\n"`, `aiur --instance t status` prints `ok` and exits 0; with exit marker 7 it exits 7.
2. The request body equals the expression the local path would pass to `bin/aiur rpc` for the same arguments (asserted for `status`, `agents --all`, `message 12 hi`).
3. `aiur status` without `--instance` sends no HTTP request and still calls `bin/aiur rpc`.
4. `aiur --instance t stop` exits 64 with "stop is local to the instance's host" and makes no request.
5. A registry URL `http://example.com` or `http://x.ts.net` is refused; `http://127.0.0.1:4000` and `https://x.ts.net` are accepted. A `token_file` with mode 0644 is refused.
6. 403 prints the required scope; 401 prints "token rejected by <name>"; neither prints the token.
7. Unknown instance name exits 64 and names `~/.aiur/remote-instances.yaml`.
8. An agent environment built by the daemon from a parent environment with `AIUR_TOKEN_NUC=x` does not contain `AIUR_TOKEN_NUC` (Elixir test next to the existing `GITHUB_TOKEN` scrub test).
9. A fake server answering 422 `unknown_on_build` makes the client print "unsupported on t" with the build and exit 64, with exactly one request sent.

### Test that fails without the change

`launcher-remote.test.mjs`: `aiur --instance t status` against the fake server expects exit 0 and output `ok`; today `--instance` is treated as a launch flag and the run fails before any request.

### At-merge gate

CI green; `website/docs-app/scripts/check-cli-reference.sh` passes.

### Human/manual evidence

With MIC-002 merged: `aiur --instance nuc status` from the PC against the NUC (recorded in MIC-010).

## Docs to update

- `website/docs-app/reference/cli.md`: one row for `--instance <name>` (consolidate rows to stay ≤ 500 lines); one short "Remote instances" paragraph with the registry format and the local-only command list.
- `website/docs-app/guide/quick-start.md` two-instance section: point at `--instance`.

## Files it touches

`packaging/npm/aiur-cli/libexec/engine/remote.sh`, `engine/control.sh`, `aiur-engine.sh`, `bin/aiur.js`, `scripts/aiurdev`, the agent-environment scrub module in `src/lib/aiur/` (find with `rg -l GH_TOKEN src/lib`) and its test, the launcher test, the two docs.

## Dependencies and conflicts

- depends_on: none.
- suggested_after: MIC-002 (the manual check needs it).
- serializes_with: #5939 on `aiur-engine.sh` (in flight; merge-time only).
- `reference/cli.md` row edits are covered by the pack's hot-file exception, not an edge.

## First slice Kevin can try

After MIC-002 and #5945 merge and the NUC is rebuilt: create a read token on the NUC (`aiur token create pc-read --scope read`), add `nuc` to `~/.aiur/remote-instances.yaml` on the PC, run `aiur --instance nuc status`.
