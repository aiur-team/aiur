Frozen build-home design data: live, dense, newrepo, noqueue and offline.
The unedited design-source is vendored from research commit 6732f5f9f448b1857a9643993849635f85321e19.
From src/browser, run `npm run fixtures:build-home` to re-export; `npm run check:build-home-fixtures` verifies it.
Infinity is encoded as a string; use the exporter's decode helper to recover numbers.
To re-import, replace design-source unchanged and re-export; the C1-T02 visual diff shows what changed.
