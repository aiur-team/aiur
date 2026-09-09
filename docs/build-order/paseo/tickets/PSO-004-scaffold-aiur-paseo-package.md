# PSO-004 — Scaffold `packages/aiur-paseo`

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 2 — package skeleton, transport framing, CI wiring; no Paseo or app-server behaviour

**Risk:** low

**Phase hint:** 1

**Depends on:** none

**Serializes with:** none

**External gates:** none

**Requirements:** R5, R14

**Decisions:** DEC-001, DEC-013, DEC-014

**Design evidence:** 00-design.md sections 2, 3, 5, 6; 01-spike-report.md section 1

**Researched at:** 8199f5373 (aiur main), paseo 726067b4, aiur-claude 1.1.0

**Suggested labels:** `complexity:2`, `model:claude`, `phase:1`, `build-lane:paseo-sidecar`; never `agent:todo`

## Outcome

`packages/aiur-paseo/` exists as a buildable, linted, tested TypeScript package that publishes to npm as `aiur-paseo` with a `aiur-paseo` binary. It parses its CLI flags, frames NDJSON over stdio, and runs in CI. It does nothing with Paseo or the app-server protocol yet; PSO-005 and PSO-006 fill the two halves on top of this layout.

## Context and evidence

The design puts every Paseo-specific line outside aiur core (DEC-001), following the two precedents already in use: `aiur-claude` (a separate npm sidecar core launches over stdio) and `packages/streamdeck` (an in-repo TypeScript package with its own CI job and release workflow). This ticket copies the streamdeck toolchain so later PSO tickets add behaviour instead of infrastructure.

Precedents to copy from, verbatim where sensible:

- `packages/streamdeck/package.json`, `tsconfig.json`, `tsconfig.test.json`, `vitest.config.ts`, `eslint.config.mjs`, `mise.toml`.
- `.github/workflows/ci.yml` job `streamdeck` (Node 24, `npm ci`, `npm run lint`, `npm test`, `npm run build`).
- `.github/workflows/streamdeck-package.yml` (artifact on PR, release on `v*` tag).
- `$(npm root -g)/aiur-claude/src/protocol.ts` and `transport.ts` (MIT) for the NDJSON framing shape.

## Scope

Create these files under `packages/aiur-paseo/`:

- `package.json`: `name: "aiur-paseo"`, `version: "0.0.0"`, `type: "module"`, `bin: {"aiur-paseo": "dist/cli.js"}`, `files: ["dist", "NOTICE", "README.md"]`, `engines: {node: ">=22"}`, scripts `build` (`tsc -p tsconfig.json && chmod +x dist/cli.js`), `lint`, `typecheck`, `typecheck:test`, `test` (`npm run typecheck:test && vitest run --coverage`), `prepublishOnly` (`npm run build`). Dependencies: `@getpaseo/client` pinned `~0.7.2`, `uuid`. Dev: `typescript`, `vitest`, `@vitest/coverage-v8`, `eslint`, `@eslint/js`, `typescript-eslint`, `@types/node`. `ws` is added by PSO-006 if the fake daemon needs it.
- `tsconfig.json`: copy of `packages/streamdeck/tsconfig.json` (ES2022, ESNext, Bundler, strict, `rootDir: src`, `outDir: dist`).
- `vitest.config.ts`: `include: ["test/**/*.test.ts"]`, v8 coverage over `src/**`, 100% thresholds, `exclude: ["src/cli.ts"]` with a comment explaining cli.ts is process wiring.
- `eslint.config.mjs`: copy of streamdeck.
- `src/cli.ts`: entry point. Parses `--provider claude|codex` (required unless `--help`, `--version`, `--check`), `--mode <id>`, `--host <host:port>` (default `PASEO_HOST` env, then `127.0.0.1:6767`), `--supported-versions <range>` (default `>=0.7.2 <0.9.0`), `--check`, `--debug`, `-h/--help`, `-V/--version`. Reads `PASEO_PASSWORD`. Exports `parseArgs(argv: string[]): ParsedArgs` from `src/cli-args.ts` so the parser is unit-tested without spawning. `--check` exits 2 with `aiur-paseo: --check not implemented yet` on stderr (PSO-006 replaces this). Default mode prints `[aiur-paseo] listening on stdio` to stderr and starts the transport with a placeholder handler that answers every request with JSON-RPC `-32601 Method not found` (PSO-005 replaces it).
- `src/rpc/protocol.ts`: port of aiur-claude `protocol.ts`: `RpcId`, `RpcRequest`, `RpcNotification`, `RpcResponse`, `RpcError`, `E` error codes (`ParseError -32700`, `InvalidRequest -32600`, `MethodNotFound -32601`, `InvalidParams -32602`, `InternalError -32603`, `NotInitialized -32000`, `ThreadNotFound -32001`, `TurnBusy -32003`, `NoActiveTurn -32004`), `RpcException`, `ok`, `rpcErr`, `notif`, `isRequest`, `isNotification`, `isResponse`, `parseLine`.
- `src/rpc/transport.ts`: `startStdio(handler: MessageHandler, io?: {input: NodeJS.ReadableStream, output: NodeJS.WritableStream}): Connection`. Uses `readline` on `input`; each line goes through `parseLine`; a non-empty line that fails to parse is answered with `rpcErr(null, E.ParseError, ...)`; a line longer than `MAX_LINE_BYTES = 1_048_576` is dropped with a stderr warning (core's `Port.open` line cap is 1 MiB, `Aiur.AppServer.Adapter.port_line_bytes/0`). `Connection` is `{initialized: boolean, send(msg: unknown): void, close(): void}`; `send` writes `JSON.stringify(msg) + "\n"`. On `input` end, calls `handler.onClose()` and resolves.
- `NOTICE`: MIT attribution for the code ported from `aiur-claude` (`its-everdred/claude-app-server`, copyright holder as in its LICENSE), stating which files derive from it.
- `README.md`: what the sidecar is, install (`npm install -g aiur-paseo`), prerequisites (`@getpaseo/cli` daemon running, `PASEO_PASSWORD`), flags table, exit codes table (0 ok, 2 usage, 3 unreachable, 4 unauthorized, 5 unsupported version, reserved for PSO-006), how aiur launches it (`agent.backend_configs.paseo-claude.command`), a "Development" section (`npm ci`, `npm test`, `npm run build`).
- `test/cli-args.test.ts`, `test/rpc/protocol.test.ts`, `test/rpc/transport.test.ts`.
- `.github/workflows/ci.yml`: add job `aiur-paseo` after `streamdeck`, identical shape with `working-directory: packages/aiur-paseo` and `cache-dependency-path: packages/aiur-paseo/package-lock.json`; add it to the `timeout-minutes` and job-inventory comment block at the top of the file if the streamdeck job is listed there (it is, around line 53).
- `.github/workflows/aiur-paseo-package.yml`: mirror of `streamdeck-package.yml` with `paths: ["packages/aiur-paseo/**", ".github/workflows/aiur-paseo-package.yml"]`. On PR and push: `npm ci`, `npm run build`, `npm pack`, upload the tarball artifact `aiur-paseo-<commit>`. On `release: published` with tag `v*`: `npm publish --provenance --access public` using secret `NPM_TOKEN` (name it; do not create it). Version is taken from `package.json`; add a step that fails when the tag version and `package.json` version differ, as `release-npm.yml` does for `aiur-cli`.
- Root `README.md`: one bullet under the feature list beside the Stream Deck bullet: "**Paseo** — chat with any agent from the Paseo mobile or desktop app through the opt-in `aiur-paseo` sidecar (`packages/aiur-paseo`)."

## Non-goals

- Any app-server method handling (PSO-005), any Paseo connection (PSO-006), the dynamic-tool bridge (PSO-010), docs pages (PSO-008).
- Publishing to npm from this ticket; the workflow is wired, the first publish happens after PSO-012.
- Bundling a Node runtime as the streamdeck archive does. `aiur-paseo` is an ordinary npm package like `aiur-claude`.

## Existing owner and reuse target

New package. Reuse streamdeck's toolchain files and aiur-claude's protocol and transport code (ported, attributed). No aiur core files change except the two workflows and the root README bullet.

## Contract and invariants

### Requirements

- PSO-004-R1. `npm ci && npm run build` in `packages/aiur-paseo` produces an executable `dist/cli.js`; `node dist/cli.js --version` prints the package version; `--help` prints usage and exits 0.
- PSO-004-R2. `parseArgs` rejects an unknown flag and a missing `--provider` with exit code 2 and a one-line usage error on stderr; `--check`, `--help`, `--version` do not require `--provider`.
- PSO-004-R3. `PASEO_HOST` and `PASEO_PASSWORD` are read from the environment; `--host` overrides `PASEO_HOST`; the password is never printed, including in `--debug` output.
- PSO-004-R4. The stdio transport frames one JSON-RPC message per line, answers unparseable non-empty lines with `-32700`, drops lines over 1 MiB with a warning, and exits 0 when stdin ends.
- PSO-004-R5. CI runs lint, typecheck, tests with 100% coverage on `src/rpc/**` and `src/cli-args.ts`, and build, on every PR touching the package.
- PSO-004-R6. The package workflow produces a tarball artifact on PR and is wired (not exercised) to publish on a `v*` release.
- PSO-004-R7. `NOTICE` names the aiur-claude origin of the ported files; the package `license` field is `Apache-2.0` to match the repo.

Invariants: core compiles and tests with this directory absent; nothing under `src/` (Elixir) changes.

## Refreshable implementation notes

- Run `npm init` by hand rather than copying streamdeck's `package-lock.json`; the dependency sets differ.
- `parseLine` in aiur-claude returns `null` for both empty and invalid lines; split those so the transport can answer `-32700` only for the invalid case.
- Keep `src/cli.ts` free of logic: it calls `parseArgs`, `startStdio`, and (later) `connectDaemon`. That is why coverage excludes it.
- Check `.github/workflows/ci.yml` for a required-check aggregator (`ci / required`); if job names feed it, add `aiur-paseo` to that list so the check stays meaningful.

### Key technical decisions

- Ordinary npm package, not a bundled archive: aiur already launches `aiur-claude` from PATH the same way, and `aiur init` installs backends with `npm install -g` (`src/lib/aiur/init/agent_cli.ex`).
- `@getpaseo/client` pinned with `~0.7.2` so a daemon major bump is a deliberate package release, not a silent drift (DEC-013).
- ESM (`type: module`) like streamdeck, unlike aiur-claude (commonjs); the MCP shim in PSO-010 must therefore be an ESM file invoked with `node`.

## Acceptance and verification

### Agent gate

- `test/cli-args.test.ts`: table over `[argv, expected]` covering every flag, defaults, env precedence, unknown flag, missing provider, `--check` without provider, password redaction in `describeArgs()`.
- `test/rpc/protocol.test.ts`: `parseLine` accepts request, notification, response; rejects wrong `jsonrpc`, non-object, bare id-less result; `ok`/`rpcErr`/`notif` shapes; `isResponse` on server-initiated request replies.
- `test/rpc/transport.test.ts`: with `PassThrough` streams: one message per line; two messages in one chunk; one message split across chunks; empty lines ignored; invalid JSON answered with `-32700` and `id: null`; a 1 MiB + 1 byte line dropped with a warning and the next line still processed; `send` appends newline; end of input triggers `onClose` exactly once.
- `npm run lint`, `npm run typecheck`, `npm test` (coverage thresholds met), `npm run build` green locally.

### At-merge gate

- CI job `aiur-paseo` green on the PR head; `aiur-paseo-package` workflow uploads a tarball artifact for the PR.
- Repo CI (`make all` in `src/`) unaffected and green.

### Human/manual evidence

- `npm pack` locally, `npm install -g ./aiur-paseo-0.0.0.tgz`, `aiur-paseo --help` and `aiur-paseo --version` print as expected. Record the output on the PR.

## Failure, security, migration, and accessibility cases

- Never log `PASEO_PASSWORD`; `--debug` logs go to stderr only (stdout is the protocol channel).
- A stdout write from any library would corrupt the NDJSON stream: pin `console.log` to stderr in `cli.ts` at startup (`console.log = console.error`) and document why.
- No migration: new package.

## Surfaces

- Reads: process argv and env.
- Writes: `packages/aiur-paseo/**`, `.github/workflows/ci.yml`, `.github/workflows/aiur-paseo-package.yml`, root `README.md`.
- Contracts: `parseArgs`, `startStdio`, `Connection`, `E` error codes, consumed by PSO-005 and PSO-006.

## Sibling boundaries and open gates

PSO-005 owns `src/server.ts` and the method dispatch; PSO-006 owns `src/paseo/*` and the real `--check`; PSO-010 owns `src/tools/*`. This ticket must not stub those modules beyond the placeholder handler named above.

## Plan context

- [Design and decisions](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/00-design.md)
- [Spike report](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/01-spike-report.md)
- [Pack index](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/README.md)
- [Requirements plan](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/plans/2026-09-09-001-feat-paseo-integration-plan.md)
- Your issue's native parent is the Build Order root; native `blockedBy` edges are the dependency graph — the root issue renders the full picture.
