# AIUR - AI Unit Runtime

> [!WARNING]
> **Use at your own risk.** Aiur is an unstable, vibecoded engineering preview for trusted
> environments only. It **bypasses all agent permission prompts** and has very few efficiency
> optimizations. Suggested for simple tasks under supervision.
>
> Workers run permission-free *inside an isolated workspace*, not against your machine or your
> main checkout, and work reaches your repo only through the Executor's review gates and merge
> policy — agents do not self-merge. That bounds the blast radius; it does not eliminate it.
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

- **You drive it.** Run `aiur` in your terminal and act as the Executor yourself: watch the CLI
  or dashboard, answer agents, apply merge policy. The CLI, TUI, and dashboard are fully
  human-drivable.
- **Your agent drives it.** Ask your coding agent to "run aiur" and it operates the run as the
  Executor — launching, monitoring the fleet, recovering stuck agents, coordinating PR review —
  while you keep talking to your agent in parallel. The bundled skills below take it from there.

Many operators mix the two: the agent runs the code-to-PR stretch, and anything needing
production credentials stays in the human's own session.

## Can Aiur watch agents it didn't launch?

No — Aiur owns the runs it dispatches. It is not a passive observer that attaches to agent
sessions started elsewhere. But your agent can operate Aiur as the Executor while you talk to it
in parallel, or you can drive Aiur directly yourself.

## Do I have to use an agent to use Aiur?

No. The CLI, TUI, and dashboard are fully usable by a human on their own. Agent-operated mode is
an option, not a requirement.

## What Aiur is not

- **Not a passive observer** of external agent sessions. Aiur runs the agents it manages; it does
  not attach to a Claude Code or Codex session you started yourself.
- **Not agent-only.** The CLI, TUI, and dashboard are fully human-drivable.
- **Not a replacement for your assistant.** It is typically its counterpart: your agent can be the
  Executor and keep talking to you while runs proceed.
- **Not a hosted service.** Aiur runs on your machine, against your tracker, with your tokens.
- **Not a merge robot.** Agents open and self-review PRs; landing is gated by the Executor.

## Using Aiur with a coding agent

Using Claude Code or Codex? You can drive Aiur yourself, or ask your agent to "run aiur" — the
bundled Executor skills take it from there:

| Skill | What it does |
|-------|--------------|
| [`aiur-intro`](.claude/skills/aiur-intro/SKILL.md) | What Aiur is, install, first run, and choosing your mode |
| [`aiur-run`](.claude/skills/aiur-run/SKILL.md) | Your agent launches and operates a run end to end as its Executor |
| [`aiur-monitor`](.claude/skills/aiur-monitor/SKILL.md) | Status board and alert feed for a live run; does not launch |
| [`using-aiur`](.claude/skills/using-aiur/SKILL.md) | The operating manual for an Aiur agent working a ticket |
| [`aiur-agent`](.claude/skills/aiur-agent/SKILL.md) | Cross-ticket events: emit, subscribe, blockers, attentions |

Ask your agent *"what is aiur?"* or *"how do I install aiur?"* and `aiur-intro` will walk you
through setup and ask which mode you want.

## Additional Capabilities

- **Claude support:** Agents can run on claude as well as codex.
- **Github issues:** In addition to Linear, agents can watch and move Github issues.
- **Tracker adapters:** configure tracker backends for board- or issue-based queues, including
  label-based state machines where the tracker supports them.
- **Implementation adapters:** configure implementation backends through Aiur's app-server
  protocol.
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

See [src/README.md](src/README.md#configuration) for the supported `.aiurconfig` options and
adapter examples.

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

That is the human-driven path. To have your coding agent operate the run instead, ask it to
"run aiur" — see [Using Aiur with a coding agent](#using-aiur-with-a-coding-agent).

See [src/README.md](src/README.md) for setup, configuration, and the `aiur` command
reference (foreground, background, and `stop` modes on Linux and macOS).

---

## Upstream

Aiur is a derivative work of OpenAI's Symphony, distributed under the Apache License 2.0.
Aiur is independent and is not affiliated with or endorsed by OpenAI. See [NOTICE](NOTICE)
for full attribution.

## License

This project is licensed under the [Apache License 2.0](LICENSE).
