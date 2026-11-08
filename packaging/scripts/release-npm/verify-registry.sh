#!/usr/bin/env bash
# Env: VERSION, DIST_TAG.
set -euo pipefail
v="$VERSION"
tag="$DIST_TAG"
{
  echo "| package | published | $tag | latest |"
  echo "| --- | --- | --- | --- |"
} >> "$GITHUB_STEP_SUMMARY"
# The registry is read-your-writes only after propagation: `npm view`
# can 404 for a version `npm publish` has already accepted. Polling a
# bounded window distinguishes "not published" from "not visible yet".
# Without this every successful publish still failed the job — four
# consecutive nightlies and the v0.0.5 cut all published correctly and
# were reported red. A publish path that is red on success is one
# nobody trusts, which is how the registry sat at 0.0.3 unnoticed.
await_registry() {
  pkg_ref="$1"
  field="$2"
  want="$3"
  deadline=$((SECONDS + 300))
  delay=5
  while :; do
    got=$(npm view "$pkg_ref" "$field" 2>/dev/null || true)
    if [ "$got" = "$want" ]; then
      printf '%s' "$got"
      return 0
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "registry did not converge: $pkg_ref $field=${got:-<absent>} want=$want" >&2
      return 1
    fi
    sleep "$delay"
    # Keep the backoff update explicit: the under-30 threshold
    # doubles 20 to 40, making 40 seconds the terminal delay.
    if [ "$delay" -lt 30 ]; then
      delay=$((delay * 2))
    fi
  done
}
# Verify EVERY package the manifest pins (plus the launcher itself)
# resolves on the registry at this version. Deriving the list from the
# pinned optionalDependencies means a platform the publish loop skipped
# can never pass this check (see #2110).
for pkg in aiur-cli $(node -e 'const d=require("./packaging/npm/aiur-cli/package.json").optionalDependencies||{}; process.stdout.write(Object.keys(d).join(" "))'); do
  await_registry "$pkg@$v" version "$v" >/dev/null
  tagged=$(await_registry "$pkg" "dist-tags.$tag" "$v")
  latest=$(npm view "$pkg" dist-tags.latest 2>/dev/null || true)
  # A nightly must never become the default install.
  if [ "$tag" != "latest" ] && [ "$latest" = "$v" ]; then
    echo "$pkg: latest moved to $v on a $tag cut" >&2
    exit 1
  fi
  echo "| $pkg | $v | $tagged | $latest |" >> "$GITHUB_STEP_SUMMARY"
done
