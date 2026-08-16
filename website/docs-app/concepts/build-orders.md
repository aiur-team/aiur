# Build Orders

A **Build Order** is a planning pack: a large feature decomposed into ticket contracts, a typed dependency graph, and that graph levelled into phases that can run in parallel without violating a dependency. It is how an Executor turns "build this feature" into work a fleet can actually take.

Build Orders is the dashboard's `/build-orders` page. Its CLI counterpart is `aiur build-orders`.

<img src="/images/dashboard/build-orders-dark.png" alt="Desktop Build Order page with a synthetic planning graph, phases, and lanes">

::: info Example data
Every screenshot in this section was captured from the shipped dashboard against an isolated fixture. Tickets, members, and graph edges are synthetic.
:::

## What a pack contains

`build-order.json` supplies members, lanes, phases, dependencies, complexity, and optional icons.

| Element | Meaning |
| --- | --- |
| **Member** | One ticket contract in the pack, draft or promoted. |
| **Dependency** | A typed edge stating that one member must land before another. |
| **Phase** | A barrier-safe level of the graph. Everything in a phase can run at once. |
| **Lane** | A thematic grouping across phases, such as a subsystem or a surface. |
| **Complexity** | The `complexity:1` to `complexity:5` routing tag each member carries. |

The page renders the discovered catalog first, then shows phases and lanes as derived views over the same graph.

## Where a pack lives

Discovery looks in the active workspace first, then the state node.

```text
.aiur/build_orders/<slug>.json              workspace mirror, written by the publisher
~/.aiur/repo/<owner>/<repo>/builds/<slug>/  daemon's canonical state projection
  build-order.json
  status.json
  tickets/<ID>.md
```

Two consequences catch people out:

- A pack left only in `docs/` is invisible.
- A pack on another branch is invisible until that branch is the daemon's active workspace, or until the publisher writes its state-node copy.

A completed planning handoff therefore includes confirming that the Build Order page actually renders the pack, its phases, its lanes, and its members.

## Draft and promoted members

A draft member is described by its `tickets/<ID>.md`. After promotion the tracker owns the ticket state and labels, and the pack becomes a view over real tickets rather than a plan for them.

Promotion is Executor-owned. Planning does not create tracker tickets on its own.

## Reading it from the terminal

```bash
aiur build-orders 1567 --json
```

Without a root, the command prints the catalog. With one root it adds graph, execution, and activity detail. `aiur analytics --build-order 1567` narrows the analytics view to that root's typed members for the current session.
