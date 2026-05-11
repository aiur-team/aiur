# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

_In this [demo video](.github/media/symphony-demo.mp4), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Fork additions

This fork keeps the upstream Linear and Codex-compatible workflow, and adds the pieces needed to
run Symphony against GitHub Issues with either Codex or Claude Code.

- **Claude Code backend:** configure `agent.kind: claude` and a `claude.command` such as
  `symphony-claude` to run Claude Code through Symphony's app-server protocol.
- **GitHub Issues tracker:** configure `tracker.kind: github`, `github.repo`, and a label prefix to
  let Symphony claim issues, move them through label-based states, push branches, and open PRs.
- **Live agent logs:** each workspace writes `logs/agent.md` and `logs/agent.ndjson`; the dashboard
  can open those logs in a live-updating modal while a run is active.
- **Dashboard auth and hosting:** the Phoenix dashboard supports Basic Auth and can be bound to a
  configured host/port for private operational access.
- **Fork workflow helpers:** repo-local `commit`, `pull`, `push`, `land`, and `linear` skills keep
  issue work, PR creation, and landing behavior consistent across runs.

See [elixir/README.md](elixir/README.md#configuration) for the supported `WORKFLOW.md` options and
examples for Linear/Codex and GitHub Issues/Claude setups.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
