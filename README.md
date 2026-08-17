# AIUR - AI Unit Runtime

> [!WARNING]
> **Use at your own risk.** Aiur is an unstable, vibecoded engineering preview for trusted
> environments only. It **bypasses all agent permission prompts** and has very few efficiency
> optimizations. Suggested for simple tasks under supervision.
>
> Each worker gets a dedicated workspace and checkout, but that separation is not by itself a
> security boundary. Depending on the configured backend sandbox policy, a permission-free agent
> may access host resources outside its workspace. Aiur's intended workflow routes changes through
> the Executor's review gates and merge policy rather than having agents self-merge.
>
> Provided "as is", without warranty of any kind. You assume all risk for any cost, token
> spend, data loss, or damage from running it. See [LICENSE](LICENSE).

Aiur turns project work into isolated, autonomous implementation runs so teams can manage work
instead of supervising individual coding sessions.

Every run has an **Executor**: the operator of the run. That is either **you**, driving the CLI
directly, or **your coding agent**, operating Aiur on your behalf while you stay in conversation
with it. Both are first-class — see [Who drives Aiur?](#who-drives-aiur) before evaluating it.

[![Aiur demo video preview](.github/media/aiur-demo-poster.jpg)](.github/media/aiur-demo.mp4)

_In this [demo video](.github/media/aiur-demo.mp4), Aiur monitors a tracker board for work
and starts isolated implementation runs for selected tasks. Each run produces proof of work such as
CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, Aiur
lands the PR safely. Engineers do not need to supervise individual coding sessions; they can manage
the work at a higher level._

## Who drives Aiur?

Either you or your agent — the **Executor** role is the same either way.

- **You drive it.** Run `aiur` in your terminal and act as the Executor yourself: use the CLI/TUI
  to answer agents and apply merge policy, and observe the run in the dashboard. The dashboard is
  read-only by default; configured writable mode adds its supported controls.
- **Your agent drives it.** Give your coding agent the repo-local skills below, then ask it to
  "run aiur." It operates the run as the Executor — launching, monitoring the fleet, recovering
  stuck agents, coordinating PR review — while you keep talking to your agent in parallel.

Many operators mix the two: the agent runs the code-to-PR stretch, and anything needing
production credentials stays in the human's own session.

## Can Aiur watch agents it didn't launch?

No — Aiur owns the runs it dispatches. It is not a passive observer that attaches to agent
sessions started elsewhere. But your agent can operate Aiur as the Executor while you talk to it
in parallel, or you can drive Aiur directly yourself.

## Do I have to use an agent to use Aiur?

No. A human can control the run through the CLI/TUI and observe it in the dashboard without using
an agent as Executor. Agent-operated mode is an option, not a requirement.

## What Aiur is not

- **Not a passive observer** of external agent sessions. Aiur runs the agents it manages; it does
  not attach to a Claude Code or Codex session you started yourself.
- **Not agent-only.** Humans can drive the CLI/TUI directly; the dashboard is read-only by default
  and exposes supported controls when writable mode is configured.
- **Not a replacement for your assistant.** It is typically its counterpart: your agent can be the
  Executor and keep talking to you while runs proceed.
- **Not a hosted service.** Aiur runs on your machine, against your tracker, with your tokens.
- **Not a merge robot.** Agents open and self-review PRs; landing is gated by the Executor.

## Using Aiur with a coding agent

Using Claude Code or Codex? You can drive Aiur yourself, or make the repository's Executor skills
available to your agent and ask it to "run aiur":

> The npm package installs the `aiur` CLI; it does not install these coding-agent skills. They are
> bundled in this source repository under `.claude/skills` (with shared Codex links under
> `.codex/skills`). Use a source checkout or your agent's supported skill-install mechanism to
> make them available to the agent that will be Executor.

| Skill | What it does |
|-------|--------------|
| [`aiur-intro`](.claude/skills/aiur-intro/SKILL.md) | What Aiur is, install, first run, and choosing your mode |
| [`aiur-run`](.claude/skills/aiur-run/SKILL.md) | Your agent launches and operates a run end to end as its Executor |
| [`aiur-monitor`](.claude/skills/aiur-monitor/SKILL.md) | Status board and alert feed for a live run; does not launch |
| [`aiur-agent`](.claude/skills/aiur-agent/SKILL.md) | The operating manual for an Aiur agent working a ticket: the label lifecycle, dev loop, complexity routing, and cross-ticket events |

Once `aiur-intro` is available to your agent, ask *"what is aiur?"* or *"how do I install aiur?"*
and it will walk you through setup and ask which mode you want.

## Additional Capabilities

- **Claude support:** Agents can run on claude as well as codex.
- **Github issues:** In addition to Linear, agents can watch and move Github issues.
- **Tracker adapters:** configure tracker backends for board- or issue-based queues, including
  label-based state machines where the tracker supports them.
- **Implementation adapters:** configure Codex and Claude through Aiur's app-server
  protocol, or use the direct OpenAI-compatible transport for native Kimi,
  native DeepSeek, and OpenRouter instances.
- **Live run logs:** each workspace writes a human-readable `logs/agent.md` transcript, which the
  dashboard opens in a live-updating modal while a run is active, plus `logs/agent.ndjson`, a
  structured per-event JSON stream that feeds the attentions feed and records agent crash reasons.
- **opencode chat panes:** the tmux CLI opens opencode-backed chat panes for live Executor
  input while Aiur keeps the Codex/Claude runtime and transcript as the source of truth.
- **Dashboard auth and hosting:** the Phoenix dashboard supports Basic Auth and can be bound to a
  configured host/port for private operational access.
- **Supervisor Decision API:** an independently authenticated machine API can inspect, enrich,
  answer, and revise durable Decisions under an explicit fail-closed delegation policy.
- **Workflow helpers:** repo-local skills and scripts keep issue work, PR creation, and landing
  behavior consistent across runs without making those workflows part of Aiur's core model. See
  [Using Aiur with a coding agent](#using-aiur-with-a-coding-agent) for the bundled skills,
  including the ones that let your agent operate a run as its Executor.
- **Optional alert sounds:** users can edit the checked-in `.aiur/alerts` file, where each alert
  defines its `name`, `message`, and optional `sound` clips in one place.

See [src/README.md](src/README.md#config) for the supported `.aiurconfig` options and
adapter examples. Build Order's optional `build_order` settings configure supervised,
in-memory configured-repository ticket-detail, typed ticket-history, and planning-graph
providers. The graph projection owns catalog and demanded-root refreshes independently of
browser count, with bounded retained roots and provider work. Restart clears all three stores:
ticket detail, ticket history, and graph snapshots remain unavailable until fresh provider
evidence succeeds.

## Project layout

Aiur's Elixir application lives in `src/`. Node packages are standalone projects under
`packages/`, so each package owns its own manifest and lockfile. The Stream Deck package is
currently a scaffold; build it with:

```bash
cd packages/streamdeck
npm ci
npm run lint
npm test
npm run build
```

For the emulator and optional hardware acceptance flow, see the
[Stream Deck end-to-end proof runbook](docs/research/streamdeck-end-to-end-proof.md).

## Running Aiur

Aiur works best in codebases with clear setup instructions, automated validation, and workflow
conventions that autonomous implementation runs can follow.

```bash
npm install --global aiur-cli   # requires Node.js 18+

cd your-project
aiur init                       # interactive setup wizard
                                # then label issues `agent:todo`
aiur                            # foreground; `aiur --bg` for headless
```

Useful controls: `aiur status`, `aiur pause`, `aiur resume`, `aiur stop`.

That is the human-driven path. To have your coding agent operate the run instead, first make the
repo-local Executor skills available to it, then ask it to "run aiur" — see
[Using Aiur with a coding agent](#using-aiur-with-a-coding-agent).

See [src/README.md](src/README.md) for setup, configuration, and the `aiur` command
reference (foreground, background, and `stop` modes on Linux and macOS). It also documents
the default 64 MiB / 30-day telemetry retention window, which preserves complete boots for
useful cross-session history.

---

## Upstream

Aiur is a derivative work of OpenAI's Symphony, distributed under the Apache License 2.0.
Aiur is independent and is not affiliated with or endorsed by OpenAI. See [NOTICE](NOTICE)
for full attribution.

## License

This project is licensed under the [Apache License 2.0](LICENSE).
