#!/usr/bin/env bash
# Trusted publishing needs npm >= 11.5.1. Node 24.5+ bundles a new enough
# npm and Node 22 never will (it tops out at 10.9.8), but the bundled
# version is not a contract, so assert it. An npm that is too old fails
# the publish with an opaque auth error instead of a clear one.
set -euo pipefail
npm install -g npm@latest
npm --version
node -e '
  const need = [11, 5, 1];
  const got = process.argv[1].split(".").map(Number);
  for (let i = 0; i < 3; i++) {
    if (got[i] > need[i]) break;
    if (got[i] < need[i]) {
      console.error(`npm ${process.argv[1]} is older than 11.5.1; OIDC trusted publishing is unsupported`);
      process.exit(1);
    }
  }
' "$(npm --version)"
test ! -f ~/.npmrc || ! grep -q _authToken ~/.npmrc
