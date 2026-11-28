# MP-R7 acceptance evidence

[#3485](https://github.com/aiur-team/aiur/issues/3485) remains open.
The 2026-11-28 UTC audit sampled `main` at
`fd275826bbafedb78d18db16cce3a02f848f82d3`.
The test checkout was `c053f9c5abaa6840a6cc3530469abd7db887dadc`,
whose only tree difference from that main SHA was the C4 disposition in
`chunks.md`. The [original acceptance criteria](https://github.com/aiur-team/aiur/blob/6732f5f9f448b1857a9643993849635f85321e19/docs/research/aiur-mobile-and-platform/bucket-1-refactor/MP-R7/plan.md#acceptance-criteria)
still govern the behavior-preservation checks. The [promotion recheck](plan.md#c4-t03-in-tree-recheck-2026-11-21)
governs physical packaging.

## Member audit

GitHub reported 19 merged PRs whose merge commits are ancestors of the sampled
main SHA. Of the other two members, one completed through a sibling issue and
one was still open.

| Members | Evidence |
| --- | --- |
| C1-T01–T04 (#3463–#3466) | #4208, #4226, #4222, #4428 |
| C2-T01–T03 (#3467–#3469) | #5025, #4427, #5441 |
| C3-T01–T06 (#3470–#3475) | #4426, #3504, #5174, #5172, #5440, #5477 |
| C4-T01–T03 (#3476–#3478) | #5200, #5475, #8091. T03 improved the in-tree boundary and kept physical promotion at no-go. |
| C4-T04 (#3479) | #8126 merged the deferral record. The physical adapter move is deferred. |
| C4-T05 (#3480) | [#8194](https://github.com/aiur-team/aiur/pull/8194) was open. It records the release-check deferral. Separate-package boot verification requires physical promotion and the adapter move. |
| C5-T01 (#3481) | #5034 |
| C5-T02 (#3483) | Completed by filing [aiur-claude#9](https://github.com/aiur-team/aiur-claude/issues/9). |
| C6-T01 (#3484) | #5479 |

## Acceptance criteria

| Criterion | Evidence |
| --- | --- |
| 1. Registry contract | The isolated tagged run passed the registered-adapter, required-key, and immediate-delivery checks. |
| 2. Delivery policies, queue flags and provider frames | The isolated tagged run passed all 168 tests. The standard invocation reported 20 failures. |
| 3. Adapter boundary | `mise exec -- bash scripts/check-components-ci.sh` passed, including 13 ratchet tests. The checker applies to the in-tree component under the promotion decision and retains its agreed allowlist. |
| 4. Existing control capability output | The tagged suite checks equality across 42 fixture profiles with current listener defaults. It compares Elixir terms and excludes the later listener field. |
| 5. Config, CLI and rendered text stay unchanged | The harness capabilities, backend catalog and priority routes tests passed (46 tests). Member merge diffs contain config validation and catalog changes. The file audit found no CLI, packaging, dashboard or TUI implementation paths. The foreground smoke remains pending. |
| 6. Foreground Codex and Claude delivery | Pending Executor smoke. |

From `src/`, `mise exec -- mix test --only r7_characterization --max-cases 4`
ran 168 tests at seed `482842` and reported 20 failures. The queue-drain and
HTTP delivery failures included a missing suite `test.yaml`. This matches the
reported temporary workflow failures in
[#6514](https://github.com/aiur-team/aiur/issues/6514) and
[#7232](https://github.com/aiur-team/aiur/issues/7232).
The same seed passed **168 tests with zero failures** after other local Mix
commands finished and the runner loaded only files containing the tag:

```zsh
files=("${(@f)$(rg -l 'r7_characterization' test | sort)}")
mise exec -- mix test --only r7_characterization --seed 482842 --max-cases 4 "${files[@]}"
```

Configuration and read-model tests, from `src/`:

```sh
mise exec -- mix test --max-cases 4 test/aiur/harness/capabilities_test.exs test/aiur/config/backend_catalog_test.exs test/aiur/config/priority_routes_test.exs
```

## Executor smoke

1. Once the member disposition is on `main`, use a clean, up-to-date main
   checkout at the Executor repository root. Record its full SHA and UTC time.
2. Follow the [foreground tmux recipe](../../../../../docs/manual-testing.md#driving-the-tui-from-a-non-tty-agent-environment)
   with `scripts/aiurdev --test --force --allow-remote`. The harness scopes
   dispatch to one sandbox ticket. From a fresh shell targeting that sandbox,
   use `scripts/aiurdev redispatch <sandbox-issue> --backend codex` for the
   first capture, then repeat with `--backend claude` for the second.
3. Use the socket and session printed by the foreground run. Select each
   running agent in pane `0.0` and press Enter. In pane
   `0.1`, ask Codex to reply with `R7-CODEX` and Claude to reply with
   `R7-CLAUDE`. Submit each message with Enter. Wait for delivery and
   capture the submitted text and matching rendered reply with
   `tmux -L "$AIUR_SOCKET" capture-pane -p -t "$AIUR_SESSION:0.1" -S -200`.
   Attach both captures to #3485 with the UTC time and tested main SHA.
   Stop the sandbox test instance using the recipe.
4. Run `scripts/aiurdev restart` on the intended daemon after the sandbox
   stops. Capture the verified release SHA and healthy `scripts/aiurdev status`
   output. Check that the verified SHA matches the checkout.
5. File any P0/P1 findings against their owning member. Record P2/P3
   findings in the [deferred ledger](../../../../../docs/build-order/deferred-findings.md).
