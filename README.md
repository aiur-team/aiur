# AIUR - AI Unit Runtime

Aiur turns project work into isolated, autonomous implementation runs so teams can manage work
instead of supervising individual coding sessions.

[![Aiur demo video preview](.github/media/aiur-demo-poster.jpg)](.github/media/aiur-demo.mp4)

_In this [demo video](.github/media/aiur-demo.mp4), Aiur monitors a tracker board for work
and starts isolated implementation runs for selected tasks. Each run produces proof of work such as
CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, Aiur
lands the PR safely. Engineers do not need to supervise individual coding sessions; they can manage
the work at a higher level._

> [!WARNING]
> Aiur is a low-key engineering preview for testing in trusted environments.

## Additional Capabilities

- **Claude support:** Agents can run on claude as well as codex.
- **Github issues:** In addition to Linear, agents can watch and move Github issues.
- **Tracker adapters:** configure tracker backends for board- or issue-based queues, including
  label-based state machines where the tracker supports them.
- **Implementation adapters:** configure implementation backends through Aiur's app-server
  protocol.
- **Live run logs:** each workspace writes `logs/agent.md` and `logs/agent.ndjson`; the dashboard
  can open those logs in a live-updating modal while a run is active.
- **opencode chat panes:** the tmux CLI opens opencode-backed chat panes for live operator
  input while Aiur keeps the Codex/Claude runtime and transcript as the source of truth.
- **Dashboard auth and hosting:** the Phoenix dashboard supports Basic Auth and can be bound to a
  configured host/port for private operational access.
- **Workflow helpers:** repo-local skills and scripts keep issue work, PR creation, and landing
  behavior consistent across runs without making those workflows part of Aiur's core model.
- **Optional alert sounds:** users can edit the checked-in `alerts.yaml` file, where each alert
  defines its `name`, `message`, and optional `sound` clips in one place.

See [elixir/README.md](elixir/README.md#configuration) for the supported `.aiurconfig` options and
adapter examples.

## Running Aiur

Aiur works best in codebases with clear setup instructions, automated validation, and workflow
conventions that autonomous implementation runs can follow.

See [elixir/README.md](elixir/README.md) for setup, configuration, and the `aiur` command
reference (foreground, background, and `stop` modes on Linux and macOS).

---

## Upstream

Aiur is a derivative work of OpenAI's Symphony, distributed under the Apache License 2.0.
Aiur is independent and is not affiliated with or endorsed by OpenAI. See [NOTICE](NOTICE)
for full attribution.

## License

This project is licensed under the [Apache License 2.0](LICENSE).
