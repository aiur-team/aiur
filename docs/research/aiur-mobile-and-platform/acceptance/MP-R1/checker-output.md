# MP-R1 checker output

Commands target main `889212aa39a2fb992da7942c6e4236f7b70be376`.
Local checkout prefixes are rendered as `<isolated-main>` or `<workspace>`;
ANSI color codes and blank output lines are removed. Result lines are otherwise unchanged.

## 01-checker-install

Working directory: `.`.

Command:

```sh
npm ci --prefix scripts/components --ignore-scripts
```

```text
SHA: 889212aa39a2fb992da7942c6e4236f7b70be376
UTC start: 2026-10-26T11:39:08.113235Z
UTC end: 2026-10-26T11:39:08.516249Z
Exit code: 0
added 1 package, and audited 2 packages in 337ms
found 0 vulnerabilities
```

## 02-checker

Working directory: `.`.

Command:

```sh
python3 scripts/check-components.py --require-elixir
```

```text
SHA: 889212aa39a2fb992da7942c6e4236f7b70be376
UTC start: 2026-10-26T11:39:08.537890Z
UTC end: 2026-10-26T11:39:25.818131Z
Exit code: 0
components: Elixir: 2406 modules, 89593 references; 25 unresolved internal targets; 15.576 s
scc: 34 components: ['accounting', 'agent-runner', 'agent-sandbox', 'build-orders', 'build-queue', 'commands', 'config', 'control-cli', 'conversations', 'dashboard-ui', 'event-bus', 'executor-attention', 'experiments', 'experiments-page', 'github', 'github-access', 'github-listeners', 'harness-adapters', 'identity', 'init', 'linear', 'orchestration', 'pr-lifecycle', 'projections', 'signal', 'streamdeck-server', 'telemetry', 'ticket-context', 'tracker', 'tui', 'voice-stt', 'web-kit', 'web-shell', 'workspace']
scc: 1 components: ['aiur-contracts']
scc: 1 components: ['aiur-style']
scc: 1 components: ['docs-site']
scc: 1 components: ['experiment-stats']
scc: 1 components: ['kernel']
scc: 1 components: ['launcher']
scc: 1 components: ['listener-modes']
scc: 1 components: ['listener-spec']
scc: 1 components: ['machine-gateway']
scc: 1 components: ['mobile-app']
scc: 1 components: ['notification-policy']
scc: 1 components: ['pairing-discovery']
scc: 1 components: ['push-relay']
scc: 1 components: ['relay-service']
scc: 1 components: ['skills']
scc: 1 components: ['streamdeck-sidecar']
scc: 1 components: ['voice-conversation']
scc: 1 components: ['voice-conversation-core']
scc: 1 components: ['watch-apps']
components: R-declared: 197 baseline keys
components: R-private: 35 baseline keys
components: R-down: 84 baseline keys
components: R-optional: 148 baseline keys
components: all 2981 source files owned
components: 30 sections, 7 fields, 96 env vars, 29 state paths owned once
components: accounting: 110 files
components: agent-runner: 87 files
components: agent-sandbox: 43 files
components: aiur-contracts: 35 files
components: aiur-style: 211 files
components: build-orders: 130 files
components: build-queue: 45 files
components: commands: 100 files
components: config: 100 files
components: control-cli: 80 files
components: conversations: 6 files
components: dashboard-ui: 211 files
components: docs-site: 0 files
components: event-bus: 37 files
components: executor-attention: 53 files
components: experiment-stats: 0 files
components: experiments-page: 14 files
components: experiments: 98 files
components: github-access: 91 files
components: github-listeners: 83 files
components: github: 120 files
components: harness-adapters: 180 files
components: identity: 13 files
components: init: 28 files
components: kernel: 35 files
components: launcher: 86 files
components: linear: 5 files
components: listener-modes: 0 files
components: listener-spec: 0 files
components: machine-gateway: 0 files
components: mobile-app: 0 files
components: notification-policy: 0 files
components: orchestration: 317 files
components: pairing-discovery: 0 files
components: pr-lifecycle: 5 files
components: projections: 40 files
components: push-relay: 0 files
components: relay-service: 0 files
components: signal: 3 files
components: skills: 5 files
components: streamdeck-server: 21 files
components: streamdeck-sidecar: 197 files
components: telemetry: 58 files
components: ticket-context: 23 files
components: tracker: 18 files
components: tui: 108 files
components: voice-conversation-core: 83 files
components: voice-conversation: 0 files
components: voice-stt: 20 files
components: watch-apps: 0 files
components: web-kit: 5 files
components: web-shell: 19 files
components: workspace: 58 files
```

## 10-config-docs

Working directory: `.`.

Command:

```sh
python3 scripts/check-config-docs.py
```

```text
SHA: 889212aa39a2fb992da7942c6e4236f7b70be376
UTC start: 2026-10-26T11:41:09.556221Z
UTC end: 2026-10-26T11:41:09.604929Z
Exit code: 0
check-config-docs: all 290 config keys are documented
```

## 11-component-docs

Working directory: `.`.

Command:

```sh
python3 scripts/check-components.py --docs
```

```text
SHA: 889212aa39a2fb992da7942c6e4236f7b70be376
UTC start: 2026-10-26T11:41:09.648214Z
UTC end: 2026-10-26T11:41:09.770708Z
Exit code: 0
components: docs references valid
```

## 12-bare-receive

Working directory: `.`.

Command:

```sh
python3 scripts/check-bare-assert-receive.py
```

```text
SHA: 889212aa39a2fb992da7942c6e4236f7b70be376
UTC start: 2026-10-26T11:41:09.811557Z
UTC end: 2026-10-26T11:41:10.305386Z
Exit code: 0
check-bare-assert-receive: OK (2383 test files)
```
