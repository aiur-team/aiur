# MIC-009 — The daemon refuses to run distributed unless Erlang distribution and epmd are loopback-only

**Kind:** executable
**Provenance:** planned in plan v1
**Extends:** #5939 and #5940 (container launch paths that may bypass the engine); new as a ticket
**Complexity:** 2 — boot check plus image cookie rule
**Risk:** high if absent (the cookie gives full code execution)
**Lane:** PC
**Phase hint:** 1
**Depends on:** none
**Requirements:** R19
**Researched at:** ab0c21424

Plan context: [plan](../../2026-10-23-001-feat-multi-instance-control-plan.md) (U9, AE8) · [pack index](../README.md)

## Outcome

No launch path, including a container entrypoint, can start a distributed Aiur node that listens beyond loopback or uses the release's built-in cookie.

## Context and evidence

- Loopback distribution is set only by the bash engine: `ERL_AFLAGS=... inet_dist_use_interface {127,0,0,1}` and `ERL_EPMD_ADDRESS=127.0.0.1` (`packaging/npm/aiur-cli/libexec/engine/identity.sh:283-302`).
- `Aiur.Distribution` documents a refusal when epmd is not loopback (`src/lib/aiur/distribution.ex:10-12`) and declares `{:error, :epmd_not_local}` (`:18`), but no code returns it; `epmd_address/0` is only read in a test (`src/test/aiur/distribution_test.exs:23-30`).
- The release shim falls back to `releases/COOKIE` when `RELEASE_COOKIE` is unset (`src/mix.exs:289-300`); an image built from the release ships that file.
- With remote control over HTTPS (MIC-002), distribution never needs to leave the host.

## Scope

- At application start, when `Node.alive?()`: check the addresses actually bound, not only the variables: the distribution listen socket's address and the address epmd listens on (an epmd started earlier on `0.0.0.0` is reused and would pass a variable-only check). Require loopback for both; otherwise log one line naming what is exposed and stop with a nonzero exit. Refresh the exact OTP calls at pickup.
- Refuse to boot distributed when the running cookie equals the content of `releases/COOKIE` (the baked default).
- Non-distributed boots are unaffected.
- `aiur doctor`: one check line reporting the same.

## Non-goals

- TLS distribution. Container entrypoint design (#5939/#5940).

## Existing owner and reuse target

`Aiur.Distribution.start!/0`, called through `Aiur.start_distribution/1` (`src/lib/aiur.ex:234`); turn the documented invariant into code.

## Contract and invariants

A distributed daemon is reachable by distribution only from its own host.

## Refreshable implementation notes

- Edit: `src/lib/aiur/distribution.ex`, the call site `Aiur.start_distribution/1` (`src/lib/aiur.ex:234`), `aiur doctor` check script under `packaging/npm/aiur-cli/libexec/`.
- Tests: `src/test/aiur/distribution_test.exs` with injected env and kernel values.

## Acceptance and verification

### Acceptance criteria

1. Distributed with epmd bound beyond loopback (for example `ERL_EPMD_ADDRESS` unset): start refuses with a message naming epmd and `ERL_EPMD_ADDRESS` (AE8).
2. Distributed with the distribution listener bound beyond loopback (`inet_dist_use_interface` unset): start refuses naming it.
3. Distributed with the cookie equal to `releases/COOKIE`: start refuses.
4. Engine-launched daemon (current flags): starts as today.
5. Non-distributed boot: unaffected.

### Test that fails without the change

`distribution_test.exs`: `Distribution.check(alive?: true, epmd_address: {0, 0, 0, 0}, dist_address: {127, 0, 0, 1})` returns `{:error, :epmd_not_local}` and `check(alive?: true, epmd_address: {127, 0, 0, 1}, dist_address: {0, 0, 0, 0})` returns `{:error, :dist_not_local}` (the bound addresses are injected; production reads them from the running node). Today no check exists and boot proceeds.

### Human/manual evidence

None beyond tests; MIC-010 records `aiur doctor` on a container instance.

## Docs to update

AGENTS.md "Auth" paragraph is not affected. Add one line to `website/docs-app/reference/cli.md` "Operational facts" stating distribution is loopback-only and remote control uses HTTPS. Add the same line to the Railway guide only if #5954 has merged; otherwise #5954 carries it (amendment A5).

## Files it touches

`src/lib/aiur/distribution.ex`, `src/lib/aiur.ex`, the doctor check, the test, one docs line.

## Dependencies and conflicts

- depends_on: none.
- suggested_after: #5939, #5940. If this ticket merges first, the container entrypoint must already export the engine's loopback flags and a non-default cookie (amendment A4), or a container boot fails. Whichever PR merges second carries the entrypoint flags and proves a container boot in its PR body.

## First slice Kevin can try

`aiur doctor` shows "distribution: loopback only".
