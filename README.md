# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

_In this [demo video](.github/media/symphony-demo.mp4), Symphony monitors a tracker board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise individual coding sessions; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Additional Capabilities

This fork keeps Symphony provider-agnostic while broadening the adapters and operational tooling
available to a deployment.

- **Tracker adapters:** configure tracker backends for board- or issue-based queues, including
  label-based state machines where the tracker supports them.
- **Agent adapters:** configure coding agents through Symphony's app-server protocol so deployments
  can choose the agent backend that fits their environment.
- **Live agent logs:** each workspace writes `logs/agent.md` and `logs/agent.ndjson`; the dashboard
  can open those logs in a live-updating modal while a run is active.
- **Dashboard auth and hosting:** the Phoenix dashboard supports Basic Auth and can be bound to a
  configured host/port for private operational access.
- **Workflow helpers:** repo-local skills and scripts keep issue work, PR creation, and landing
  behavior consistent across runs without making those workflows part of Symphony's core model.

See [elixir/README.md](elixir/README.md#configuration) for the supported `WORKFLOW.md` options and
adapter examples.

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
