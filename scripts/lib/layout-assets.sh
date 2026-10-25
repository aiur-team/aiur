#!/usr/bin/env bash
# Shared by dev and distribution builds; stdout remains available to callers.
build_layout_assets() {
  local root="$1"
  shift
  if (cd "$root/src/browser" && "$@" npm ci --ignore-scripts && "$@" npm run vendor:elk -- --check) >&2; then
    return 0
  fi
  echo "ELK asset generation failed; release build stopped. Install Node/npm and retry:" >&2
  printf '  cd %q && npm ci --ignore-scripts && npm run vendor:elk -- --check\n' "$root/src/browser" >&2
  echo "An offline first build needs the pinned npm packages in the npm cache." >&2
  return 1
}

layout_assets_stale() {
  local root="$1" reference="$2" asset
  for asset in elk-worker.min.js aiur-layout-worker.js aiur-layout-client.js; do
    [ -f "$root/src/priv/static/vendor/elk/0.11.1/$asset" ] || return 0
  done
  [ -n "$(find "$root/src/browser/layout" "$root/src/browser/scripts/vendor-elk.mjs" \
    "$root/src/browser/scripts/layout-worker-source.mjs" "$root/src/browser/package.json" \
    "$root/src/browser/package-lock.json" "$root/src/priv/static/vendor/elk/0.11.1/manifest.json" \
    "$root/scripts/lib/layout-assets.sh" -newer "$reference" -print -quit 2>/dev/null)" ]
}
