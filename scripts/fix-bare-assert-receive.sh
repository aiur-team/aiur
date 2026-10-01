#!/bin/bash
# Fix bare assert_receive/refute_receive by adding explicit timeouts
# assert_receive gets 1000ms (1 second) for handshake overhead
# refute_receive gets 0 (immediate check, no delay)

set -euo pipefail

find src/test -name "*_test.exs" -type f | while read -r file; do
    # Backup original
    cp "$file" "$file.bak"

    # For assert_receive, add 1000ms timeout if not already present
    # Pattern: assert_receive <pattern> (no comma/timeout at end of line)
    sed -i '
        # Match assert_receive pattern ending with } but NO timeout
        /^\s*assert_receive.*}[^,]*$/ {
            # Check if line already has a timeout (contains ", <digits>")
            /,[[:space:]]*[0-9]/ ! {
                # No timeout found, add it
                # But we need to add it before the closing brace or paren
                s/\(^\s*assert_receive.*\)\([[:space:]]*\)$/\1, 1000\2/
            }
        }
    ' "$file"

    # For refute_receive, add 0ms timeout if not already present
    sed -i '
        /^\s*refute_receive.*}[^,]*$/ {
            /,[[:space:]]*[0-9]/ ! {
                s/\(^\s*refute_receive.*\)\([[:space:]]*\)$/\1, 0\2/
            }
        }
    ' "$file"

    # Check if file changed
    if ! diff -q "$file" "$file.bak" >/dev/null 2>&1; then
        echo "Fixed: $file"
    fi

    rm "$file.bak"
done

echo "Done fixing bare assert_receive/refute_receive calls"
