# Deployment verification checkpoint

Claim meta-08 remains open for its complete historical episode and build-age
surface audit. The checks below establish the launcher path independently of
the historical narrative. Code revision: `3339b887`.

## Confirmed launcher boundary

`launcher-control-audit.json` evaluates only two pure classification functions
from `scripts/aiurdev`, without running the launcher or touching a release.
For a same-checkout invocation:

- `status`, `agents`, `pause`, `resume`, `stop` and `message` select
  `ensure_control_surface`, which reuses a complete release.
- `executor-wait` and `watch` select `ensure_built`. If freshness checks require
  a build, these informational/control operations can rewrite the release.
- `restart` selects its own after-stop rebuild path. An incomplete release is
  an explicit exception: a repair build can precede the stop.

These are conditional paths, not a claim that every command always rebuilds.
`AIUR_SKIP_BUILD`, release completeness and divergent-checkout handling change
the behavior. The source branch selection is at lines 746–759; the pure
classification is at 500–516 and release reuse at 518 onward.

The public issue #2656 remains open at this audit. Its September 16 report
records an `executor-wait` rebuild against a shared release and defines a
sentinel-release regression requirement. The frozen source still contains the
classification omission. The issue is historical incident evidence; the probe
is independent current-source evidence. No live reproduction was attempted,
because it could rewrite the shared release under operating daemons.

## Distinctions needed in the design

A merged commit, checked-out source, assembled release and running daemon are
four different versions. `release_matches_head` compares the release stamp to
checkout HEAD, not the running daemon to upstream main. The restart receipt
checks that the replacement release matches the build it just requested.
The engine's `warn_if_cli_behind_release_checkout` compares installed and
checkout CLI package versions. None of those specific comparisons establishes
that a running daemon has loaded the newest merged fix.

The dev shim already builds automatically on selected paths; the activation
gap is not simply an absence of automation. Release isolation and command
classification need explicit contracts. Preserve intentional global pause and
other durable operator intent across restart. A reported lost worktree is a
separate preservation defect to investigate, not a reason to clear pause.

No complete negative claim about every build-age surface is made here. The
remaining check must inspect runtime identity/status surfaces and the named
historical incidents before deciding what freshness reporting is missing.
The evidence supports protecting live artifacts and exposing version identity;
it does not by itself choose hot upgrade over controlled restart.

## Reproduction

```sh
python3 tooling/launcher_control_probe.py "$FROZEN_SNAPSHOT"
```

The script extracts and executes only the reviewed pure classification function
bodies. It does not source the full launcher. Source hashing anchors the result
to the frozen script. A second run reproduced the saved JSON exactly.

## Version surfaces inspected after the launcher checkpoint

The source audit in deployment-surface-audit.json distinguishes four existing
surfaces. This refines the report's broad deployment narrative without claiming
the full historical compound claim has been verified.

| Surface | What it establishes | What it does not establish |
|---|---|---|
| CLI version (cli.ex:8–16,64–77; engine 501–512) | Compile-time revision/version of the invoked release, plus CLI package version | Running daemon identity: the engine launches a separate distribution-free one-shot process |
| Published upgrade notice (upgrade.ex:1–75,160–222) | Installed package version versus its npm channel, with cache/opt-outs | Running dev daemon versus upstream main; dev-launcher checks deliberately return without notice |
| Restart receipt (engine 3605–3647) | Requested rebuild location/SHA matches the on-disk replacement stamp; unknown/dirty provenance is named | Deployment of every merged commit, or identity of a different already-running daemon |
| Installed upgrade guard (engine 3888–3909) | Refusal when the selected control-plane liveness probe is up, unless forced | Safety for every other instance sharing the same artifacts |

The engine's notice path also gates on stderr being a TTY, environment opt-outs,
CI and dev release location (3780–3805). An existing optional notice should not
be described as universal freshness reporting or as entirely absent. Status
uses an actual control RPC, whereas --version does not; further status payload
and dashboard inspection is needed before asserting that no running-build field
exists anywhere.

These distinctions suggest separate acceptance criteria for the eventual plan:
capture immutable running-process build identity, expose the disk release and
checkout identities separately, name the comparison target and observation age,
and preserve shared-release ownership during build/upgrade. No automatic
restart or hot-upgrade policy follows from these observations alone.

The named historical handoffs were located and selectively inspected. They
support reports of stale releases and operator recovery work, but contain later
appended updates; filenames are not observation end-times. Their duration and
restart-side-effect claims still need episode-level verification. Nothing from
machine-specific paths, private workload context or host identity was copied.
Meta-08 remains open; both-lens coverage stays 50/60.
