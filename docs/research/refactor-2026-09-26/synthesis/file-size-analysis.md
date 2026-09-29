# Physical file size baseline

The complete frozen `3339b887` extraction contains 3,378 tracked paths. The
reproducible [census](file-size-census.json) counted 3,293 UTF-8 text files,
47 binary files and 38 symlinks; no tracked path was missing.
There are **359 text files above the hard 500-line target** and 1,192 above
the preferred 200-line target. These are baseline violations for a future
refactor, not violations introduced by the Muse branch.

The script counts LF-separated physical lines, including blanks and comments;
an unterminated nonempty last line counts. Symlink targets are not counted a
second time. Binary files have no meaningful physical-line count. This
inventory does not grant generated, vendored or archival text an exception.

| Area | Files above 500 |
| --- | ---: |
| `src/lib` | 109 |
| `src/test` | 136 |
| Other `src` | 23 |
| `docs` | 37 |
| `.claude` | 28 |
| `packages` | 9 |
| `website` | 7 |
| Other tracked text | 10 |
| **Total** | **359** |

The largest code seams are `DecisionStore` (4,826), `AgentControlCLI`
(3,408), dashboard LiveView (2,858), `Orchestrator.Dispatcher` (2,670),
`Orchestrator.PauseResume` (2,471), `Orchestrator.IssueSync` (2,295), and
`GitHub.ResourceStore` (2,191). Large tests and the launcher are independent
workstreams: splitting a production module alone does not lower the tracked
file count to zero violations. The 10,273-line dashboard CSS and 6,312-line
vendored ELK worker also require a repository policy decision and concrete
decomposition or replacement before a universal gate can pass.

## Planning implications

1. Assign every oversized file in the JSON census to an owning component and
   a reviewed disposition. New modules should describe one responsibility and
   stable interface; moving arbitrary line ranges into `part_1` files is not
   an accepted decomposition.
2. Add a repository gate that counts every tracked text file under the same
   convention. First enforce it on new or changed files while the baseline
   backlog is retired, with an explicit, counted baseline ledger; then switch
   to a universal hard gate when the ledger is empty. The transitional ledger
   is a migration schedule, not a permanent exception to 500 lines.
3. Keep the 200-line threshold as a review prompt: a larger file needs a
   cohesion explanation, but a 201-line module is not mechanically split.
4. Generated and vendor text need an explicit disposition (regenerate into
   bounded modules, replace the dependency, or cease tracking the generated
   artifact). Do not silently exclude their paths from the hard gate.

These counts are measured on `3339b887`; the final plan must refresh the
census against its implementation base and include Muse-owned files.
