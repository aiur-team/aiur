#!/bin/sh
set -eu
package=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
exec sh "$package/../../../packages/gh-access/build.sh" --output "$package/libexec/gh-access"
