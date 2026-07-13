# Build Order Planning Validation

Validated 2026-07-13 against the consolidated single-manifest planning pack on
`build-order-research`.

## Candidate status

The planning baseline is mechanically valid and ready for final semantic
review and immutable approval. Publication itself remains pending: no issue
identity, root membership, blocker relation, label, or reconciliation comment
is authorized until `publication.json.approved_planning_commit` is replaced by
the reviewed 40-character commit SHA.

## Validated boundary

- One non-dispatchable Build Order root.
- 54 direct members: BO-001..020 and DASH-001..034.
- One parentless human skill-delivery issue outside the feature denominator.
- 56 total issue identities.
- 105 member `depends_on` edges plus two external skill blockers, for 107
  native `blockedBy` relations.
- One canonical member manifest/core receipt in `build-order.json` and one
  auxiliary root/skill receipt in `publication.json`.
- Every member has exactly one `complexity:N`, one `phase:N`, one of the five
  `build-lane:*` labels, and exactly `model:codex-gpt-5.6-terra`.
- Generic `model:codex`, Sol, Luna, Claude model labels, other Codex variants,
  and every unexpected routing-family label fail validation.
- Root and skill issues remain parentless; all 54 executable issues have the
  one root as their direct native parent.

## Mechanical validation

| Gate | Current result |
|---|---|
| Vendored canonical validator | 0 errors, 0 warnings |
| Consolidated publication validator | 0 errors, 0 warnings |
| Vendored `/aiur-build` validator suite | 115 tests pass |
| Publication regression suite | 103 tests pass |
| Ticket documents | All 54 manifest paths resolve and agree with structured records |
| Hard-edge graph | 105 internal edges; acyclic; all references resolve |
| Publication graph | 56 identities, 54 root members, 107 blockers |
| Model projection | Exact Terra label on all members; generic/Claude/other variants rejected |
| Whitespace | `git diff --check` clean |

The validation commands are:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 \
  .claude/skills/aiur-build/scripts/validate_build_order.py \
  docs/build-order/build-order.json
PYTHONDONTWRITEBYTECODE=1 python3 \
  docs/build-order/scripts/validate_publication.py
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s .claude/skills/aiur-build/scripts/tests -p 'test_*.py'
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s docs/build-order/scripts/tests -p 'test_*.py'
git diff --check
```

The canonical validator owns the core v3 membership, label, dependency, title,
body, marker, and issue-state receipt for the root and all 54 members. The
publication validator owns the auxiliary v2 root/skill contract, the two
external skill blockers, exact standalone parenthood, title/body/marker/state
evidence, and the uniquely marked reconciliation comment. Both receipts are
required; the retired companion receipt and `dashboard-companions.json` are not
publication inputs.

## Skill authority

Execution requires the final reviewed PR #1065 source head
`6447f9c193d2322d63f54a58b9c54e0a72d3e98f` and its squash-merged `main`
commit `ed1846c4bc76d4657095da57951a0dbf3e914c3d` to be recorded on the live
root. The publication receipt adapter pins the reviewed source head's core v3
receipt modules; GATE-002 additionally confirms `/aiur-build`, `/aiur-run`, and
`/aiur-monitor` are discoverable from the landed merge.

## Publication reconciliation

Pending final clean semantic reviews and immutable approval. Publication must
create or reconcile only the root, all 54 members, and SKILL-DELIVERY-001; it
must not mutate read-only #132, #845, #1033, #1034, or #1067. After every live
identity, title, body, label, state, parent, subissue, and blocker is re-read,
the materializer records both receipts and the unique pending root comment.
The read-only final verifier then performs two identical bounded live snapshots
immediately before and after the one pending-to-successful comment edit.

No issue may receive an `agent:*` label during this planning run.
