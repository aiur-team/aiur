# Plan refresh tool

`scripts/plan_refresh.py` is a source-checkout tool, not part of the installed `aiur` command. It writes a Markdown report of file moves, component paths, migration-plan rows, stale citations, and oversized-file ownership. It never edits tickets or contracts.

```sh
python3 -I scripts/plan_refresh.py --repo /path/to/aiur \
  --from OLD_MAIN_SHA --to NEW_MAIN_SHA \
  --pack docs/research/aiur-mobile-and-platform --pack-ref RESEARCH_SHA \
  --u8-ledger /path/to/assignments.csv --out /path/to/report.md
```

All arguments except `--pack-ref` are required. Without it, `--pack` is a local directory; with it, the pack path is relative to the repository tree at that commit. The ledger and output paths are local filesystem paths.

The ledger must carry the columns `path,release_lines,package,frozen_owner,frozen_disposition,confidence`.

Missing component manifests leave file-level reporting available. Unresolvable citations and migration rows stay explicit in the report, and possible file splits need human inspection.

Contract rows show `status`, `base_main_sha`, and `date` without judging compatibility.

Exit 0 means the report was written, even when drift exists. Exit 2 means invalid input, a Git failure, or an I/O failure.
