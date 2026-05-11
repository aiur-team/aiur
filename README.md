# Symphony

Symphony turns project work into isolated, autonomous implementation runs so teams can manage work
instead of supervising individual coding sessions.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

_In this [demo video](.github/media/symphony-demo.mp4), Symphony monitors a tracker board for work
and starts isolated implementation runs for selected tasks. Each run produces proof of work such as
CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, Symphony
lands the PR safely. Engineers do not need to supervise individual coding sessions; they can manage
the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Additional Capabilities

Symphony keeps orchestration provider-agnostic while letting each deployment choose the tracker,
implementation backend, and operational tooling that fit its environment.

- **Tracker adapters:** configure tracker backends for board- or issue-based queues, including
  label-based state machines where the tracker supports them.
- **Implementation adapters:** configure implementation backends through Symphony's app-server
  protocol.
- **Live run logs:** each workspace writes `logs/agent.md` and `logs/agent.ndjson`; the dashboard
  can open those logs in a live-updating modal while a run is active.
- **Dashboard auth and hosting:** the Phoenix dashboard supports Basic Auth and can be bound to a
  configured host/port for private operational access.
- **Workflow helpers:** repo-local skills and scripts keep issue work, PR creation, and landing
  behavior consistent across runs without making those workflows part of Symphony's core model.

See [elixir/README.md](elixir/README.md#configuration) for the supported `WORKFLOW.md` options and
adapter examples.

## Running Symphony

### Requirements

Symphony works best in codebases with clear setup instructions, automated validation, and workflow
conventions that autonomous implementation runs can follow. Symphony is the next step: moving from
managing individual agent sessions to managing the work that needs to get done.

### Option 1. Make your own

Use an implementation agent or your own engineering process to build Symphony in a programming
language of your choice:

> Implement Symphony according to the following spec:
> ./SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask an implementation agent to help
with the setup:

> Set up Symphony for my repository based on
> ./elixir/README.md

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
