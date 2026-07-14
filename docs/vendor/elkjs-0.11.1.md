# ELK.js 0.11.1 vendor record

Aiur vendors the ELK.js `0.11.1` layout runtime for the graph geometry worker. It is not loaded from a CDN and is never exposed to dashboard hooks or product state.

- npm tarball: `https://registry.npmjs.org/elkjs/-/elkjs-0.11.1.tgz`
- npm integrity: `sha512-zxxR9k+rx5ktMwT/FwyLdPCrq7xN6e4VGGHH8hA01vVYKjTFik7nHOxBnAYtrgYUB1RpAiLvA1/U2YraWxyKKg==`
- license: EPL-2.0, copied verbatim to `src/priv/static/vendor/elk/0.11.1/LICENSE.md`
- runtime: `lib/elk-worker.min.js`, loaded only inside Aiur's dedicated worker. ELK's bundled facade tries to create another browser worker, so this pinned single-thread engine is the compatible artifact for the outer-worker design.

`src/priv/static/vendor/elk/0.11.1/manifest.json` is the source of truth for the exact files, SHA-256 values, byte sizes, and content-addressed same-origin URLs. The runtime directory intentionally excludes source maps. `PROVENANCE.md` duplicates the reviewer-facing pin, integrity, license location, size ceiling, and local URLs.

## Reproducing and upgrading

From `src/browser`, after an approved package update:

```sh
npm ci --ignore-scripts
npm run vendor:elk
npm run check:elk
```

`vendor:elk` copies only the approved engine, license, authored worker, and DOM-free client. `check:elk` compares the committed engine/license to the exact lockfile package, checks hashes and size bounds, rejects source maps, and verifies each public URL changes with its bytes.

An ELK upgrade must be reviewed as a protocol/runtime change: verify the release, license, integrity, size, browser-worker fixtures, and packaged-release check before changing the pin. PR CI builds an actual production OTP release, validates both its and the copied platform package's asset records, then loads the packaged Worker offline under a self-only CSP. The release workflow repeats the asset validation for every publishable target.
