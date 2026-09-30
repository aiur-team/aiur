# Reconciled P2/P3 overlays on merged `f223f30ea`

The effective P2/P3 audit still covers 889/889 canonical findings with 17 reconciliation overlays, yielding 244 provisional fixes and 645 deferrals. Exact cited-line comparison against `f223f30ead855c1f88ea188fb8f9cf74414ffb90` finds 15 overlay entries byte-identical at their citations and two whose citations changed or moved: `agent-backends-oc-30` and `github-b-14`. Byte identity does not prove behavior or incidence.

| Changed overlay | Current-main source observation | Decision gate |
| --- | --- | --- |
| `agent-backends-oc-30` | Slot workspace remains `~/.local/share/aiur/opencode-slot-N`; attach debug path remains `/tmp/aiur-debug/slot-N-attach.log`. `WorkspaceSetup` writes `opencode.json` with `File.write/2` and no explicit `0600`; `SessionGC` still selects Aiur-owned sessions against an active-title set. | Preserve separate Aiur instance identities in workspace and GC scope, verify whether Opencode session listing is workspace-scoped, and set restrictive token-file mode with a focused multi-instance test. Do not infer cross-instance deletion without a scoped session-list reproduction. |
| `github-b-14` | `Transport.require_token(opts)` still returns literal `"test-gh-token"` when `:request_fun` is present without a token; `IssueDependencies` still selects its REST BFS based on that option. | Remove test-only production branches only after tests inject an explicit token and fake graph transport; verify no production caller uses the seam intentionally. Preserve GitHub admission/cost accounting when consolidating. |

These two remain source-supported candidates for complexity reduction, not observed production incidents. Review the 15 unchanged overlays for current caller and reachable-population evidence before making their provisional dispositions worker-ready.
