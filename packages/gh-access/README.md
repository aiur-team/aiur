# gh-access

A standalone GitHub CLI wrapper built from Aiur's budget and answer-cache
fragments. Requires `gh`, Python 3, and a POSIX shell. No Aiur daemon is needed.

```sh
make -C packages/gh-access test
make -C packages/gh-access install PREFIX="$HOME/.local"
gh-access api repos/OWNER/REPO/issues/123
```

`aiur-cli` also ships the `gh-access` command. Separate npm/pip packages are
not published. Build outputs are untracked; `aiur-cli` composes them at pack time.

Merge/approve commands pass through by default. To build with their refusal on:

```sh
make -C packages/gh-access install BUILD_FLAGS=--deny-merge
```

Aiur's agent build always includes its own policy; it has no policy-disable flag.
See [the documentation](../../website/docs-app/apis/gh-access.md) for auth,
shared state and the cache contract. This wrapper claims no measured saving.
