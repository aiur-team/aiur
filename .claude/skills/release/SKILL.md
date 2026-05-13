---
name: release
description: "Release a new version of Symphony: bump version in mix.exs, create git tag, push to origin, create GitHub Release, and trigger Homebrew formula auto-update. Use when the user says /release, 'release a new version', 'bump version', 'create a release', or 'tag a new version'."
---

# Release Workflow

Tag, release, and publish a new version of Symphony. Pushing a tag triggers the `bump-homebrew` GitHub Action which auto-updates the `sapsaldog/homebrew-symphony` tap formula.

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

Update `elixir/mix.exs` version field to match the new version (without `v` prefix). This is the single source of truth — CLI, Codex, and Claude coding agents all read from it via `Mix.Project.config()[:version]`.

Rebuild escript and verify:
```bash
cd elixir && mix escript.build && ./bin/symphony --version
```

Commit the version bump before tagging.

### 4. Create Tag and Push

```bash
git tag -a VERSION -m "Release VERSION"
git push origin VERSION
```

### 5. Create GitHub Release

```bash
gh release create VERSION --generate-notes --title "VERSION" --repo sapsaldog/symphony
```

Note: `--repo` flag is needed because upstream remote points to openai/symphony.

### 6. Summary

After completion, show:
- Tag pushed: `VERSION`
- GitHub Release URL
- GitHub Actions link: `https://github.com/sapsaldog/symphony/actions/workflows/bump-homebrew.yml`
- Homebrew tap: `sapsaldog/homebrew-symphony` auto-updated

### Re-release (same version)

If a tag already exists and needs to be recreated:
```bash
gh release delete VERSION --repo sapsaldog/symphony --yes
git tag -d VERSION
git push origin :refs/tags/VERSION
# Then proceed from step 4
```

## Edge Cases

- **Uncommitted changes**: Block release. Tell user to commit or stash first.
- **Not on main**: Warn but allow if user confirms.
- **Tag exists**: Offer to delete and recreate, or suggest a different version.
- **No `gh` CLI**: Fall back to manual instructions for GitHub Release creation.
