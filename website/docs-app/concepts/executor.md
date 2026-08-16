# Executor

The Executor is a role, not a user account. A human fills it, or the human designates an agent to drive on their behalf.

The role runs Aiur, assigns tickets to agents, and tracks how tickets are progressing. Concretely that means launching and operating a run, keeping a supply of `agent:todo` work available, and reading the live state so nothing stalls.

## Who drives

- **A human.** You launch `aiur`, watch the [TUI](/guide/tui) or the [Dashboard](/guide/executor-control-center), and answer questions agents raise.
- **An agent.** The human designates an agent as the Executor. It drives the run over the CLI and dashboard exactly as a person would, because `aiur --bg` keeps every control surface available without a terminal board.

Even when a human runs Aiur themselves, using a second agent to help analyse progress is recommended. The second agent parses logs far faster than a person can, so it catches snags, blockers, and background issues earlier than a manual read would.

## The Executor's surfaces

- The [Dashboard](/guide/executor-control-center) combines the fleet, the decision inbox, Build Orders, and analytics in one browser view.
- The [CLI](/reference/cli) gives the same facts and controls from a terminal, which is how an agent Executor drives.
- The [Message Bus](/concepts/message-bus) is how agents raise issues to the Executor and how the Executor responds.

## Keeping tickets moving

The Executor routes work by maintaining ticket labels. `agent:todo` queues a ticket, and the label lifecycle ([How a ticket flows](/concepts/ticket-lifecycle)) carries it through review. When an agent flags an issue, it becomes a [Command](/concepts/commands) the Executor resolves.
