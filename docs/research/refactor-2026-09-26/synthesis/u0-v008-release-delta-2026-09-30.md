# v0.0.8 release source census

The [complete UTF-8/LF census](u0-v008-size-census-2026-09-30.json) counts the clean `v0.0.8` release commit `ed43c0e9442c46b9c2000ca23bddf40c13d2efb4`: 3,439 tracked paths, 3,351 text files, 47 binary files, 41 symlinks, 1,189 text files above 200 lines, and **357 above 500 lines**. No tracked path is missing. All 357 oversized paths match the distinct paths in [U8's release-head owner assignments](u8-release-007/assignments.csv); no new or retired oversized path changes the owner set.

Compared with the [8f17 checkpoint](u0-main-size-census-8f17-2026-09-30.json), only two oversized paths changed physical line count: `src/lib/aiur/test_reset.ex` grew from 832 to 847 lines and `src/test/aiur/test_reset_test.exs` grew from 537 to 632 lines. These are the reset fixes merged before v0.0.8. The count is source evidence only: it does not establish a runtime problem, net saving, or a permissible split. Recount the clean implementation head before installing a size gate, and validate the reset behavior before changing either owner boundary.

Reproduction from a clean `v0.0.8` worktree:

```sh
python3 docs/research/refactor-2026-09-26/tooling/file_size_census.py \
  ed43c0e9442c46b9c2000ca23bddf40c13d2efb4 \
  <clean-v0.0.8-worktree> --repository . \
  > docs/research/refactor-2026-09-26/synthesis/u0-v008-size-census-2026-09-30.json
```
