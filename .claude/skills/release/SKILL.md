---
name: release
description: "Release a new version of Aiur: bump version in mix.exs, create git tag, push to origin, create GitHub Release, and trigger Homebrew formula auto-update. Use when the user says /release, 'release a new version', 'bump version', 'create a release', or 'tag a new version'."
---

# Release Workflow

Tag, release, and publish a new version of Aiur via npm (the `release-npm` workflow publishes the launcher + platform packages on a `v*` tag).

> **Homebrew auto-update is currently disabled.** The `bump-homebrew` workflow's tap repo (`its-everdred/homebrew-aiur`) and `HOMEBREW_TAP_TOKEN` secret aren't set up, so releases are **npm-only**. Re-enable the tag trigger in `.github/workflows/bump-homebrew.yml` once the tap + token exist.

## Procedure

### 1. Pre-flight Checks

Run these checks and stop if any fail:

```bash
git rev-parse --is-inside-work-tree
git status --porcelain
git branch --show-current
git describe --tags --abbrev=0 2>/dev/null
git log $(git describe --tags --abbrev=0 2>/dev/null)..HEAD --oneline 2>/dev/null || git log --oneline -10
```

Display to the user:
- Current branch (warn if not `main`)
- Latest existing tag
- Commits since last tag
- Any uncommitted changes (block if dirty)

### 2. Ask for Version

Suggest the next logical version based on the latest tag. Version must match `v\d+\.\d+\.\d+`.

Verify the tag doesn't already exist:
```bash
git tag -l "VERSION"
```

### 3. Bump Version in mix.exs

Update `src/mix.exs` version field to match the new version (without `v` prefix). This is the single source of truth — CLI, Codex, and Claude coding agents all read from it via `Mix.Project.config()[:version]`.

Rebuild escript and verify:
```bash
cd src && mix escript.build && ./bin/aiur --version
```

Commit the version bump before tagging.

### 4. Create Tag and Push

```bash
git tag -a VERSION -m "Release VERSION"
git push origin VERSION
```

### 5. Create GitHub Release

```bash
gh release create VERSION --generate-notes --title "VERSION" --repo aiur-team/aiur
```

Note: pass `--repo aiur-team/aiur` explicitly so the release lands on the canonical repo even when the local remote is a fork or workspace clone.

### 6. Summary

After completion, show:
- Tag pushed: `VERSION`
- GitHub Release URL
- npm: `aiur-cli` + platform packages published by the `release-npm` workflow
- Homebrew: **not** auto-updated (the `bump-homebrew` tag trigger is disabled until the tap + token are set up)

### Re-release (same version)

If a tag already exists and needs to be recreated:
```bash
gh release delete VERSION --repo aiur-team/aiur --yes
git tag -d VERSION
git push origin :refs/tags/VERSION
# Then proceed from step 4
```

## Edge Cases

- **Uncommitted changes**: Block release. Tell user to commit or stash first.
- **Not on main**: Warn but allow if user confirms.
- **Tag exists**: Offer to delete and recreate, or suggest a different version.
- **No `gh` CLI**: Fall back to manual instructions for GitHub Release creation.
