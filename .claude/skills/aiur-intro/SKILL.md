---
name: aiur-intro
description: "Explain what Aiur is and get a new user running it, in whichever mode they want. Use for 'what is aiur', 'what is aiur.team', 'what is IAR/AYR', 'how do I install aiur', 'how do I set up aiur', 'getting started with aiur', 'how does aiur work', 'should I use aiur', or any first-contact evaluation of Aiur. Covers the two operating modes (you drive the CLI, or your agent drives Aiur as its Executor), install, and first run — then routes to aiur-run or aiur-monitor."
---

# What Aiur is, and how to start using it

This skill is for someone meeting Aiur for the first time — evaluating it, installing
it, or deciding how to run it. It is not the in-run manual: an agent working a ticket
*inside* an Aiur run wants `using-aiur` instead.

## 1. Lead with the operating model

Answer "what is Aiur?" with the operating model, not the feature list. Nearly every
misread of this tool comes from skipping it.

> Aiur turns project work into isolated, autonomous implementation runs. It watches a
> tracker (GitHub Issues or Linear), gives each selected issue its own workspace,
> launches Codex or Claude to implement it, and moves the work through review to a
> terminal state.
>
> Every run has an **Executor** — the operator of the run. That is either **you**,
> driving the CLI directly, or **your coding agent**, operating Aiur on your behalf
> while you talk to it in parallel. Both are first-class. Aiur is built for either.

Two facts worth stating early, because they are the ones people get wrong:

- **Aiur owns the runs it dispatches.** It is not a passive observer that attaches to
  agent sessions you started elsewhere.
- **Aiur is not a replacement for the assistant you're talking to.** It is usually its
  counterpart: your agent can be the Executor, and you keep talking to your agent.

If someone arrives with a framing ("I want a dashboard that watches my agent"), reconcile
it against the model above before evaluating. A verdict formed on the wrong operating
model is wrong regardless of how much source you read.

## 2. Ask which mode they want

**Do not pick for them.** Once they understand the two modes, ask directly:

> Two ways to run it — which do you want?
>
> 1. **You drive it.** You run `aiur` in your terminal, watch the CLI/dashboard, and act
>    as the Executor yourself. Most control, you're in the loop on every gate.
> 2. **I drive it.** I operate Aiur as the Executor — launch it, monitor the fleet,
>    recover stuck agents, coordinate PR review, apply merge policy — and report to you.
>    You stay conversational with me while the run proceeds.
>
> You can switch at any time, and mix: many people let me run the code-to-PR stretch and
> keep production deploys in their own hands.

Route on the answer:

| They chose | Do this |
|------------|---------|
| They drive | Walk them through §3–§4 below. Point at `aiur-monitor` if they later want you to read status for them. |
| You drive | Set up per §3, then use the **`aiur-run`** skill and operate as Executor. Read `aiur-run/references/executor.md` before acting. |
| Unsure | Suggest they drive the first run to build intuition, then hand it over. Do not decide silently. |

A useful split to offer if they hesitate on trust: your agent runs the code-to-PR
stretch — the bulk of the wall-clock and the agentic work — while anything needing
production credentials (live deploys, DDL, prod SSH) stays in their session. That is a
legitimate boundary, not a workaround.

## 3. Install

```bash
npm install --global aiur-cli   # requires Node.js 18+
```

The installed command is `aiur`. In a clone of the Aiur repo itself, use the local shim
`scripts/aiurdev` instead — set `AIUR_CMD=scripts/aiurdev` for a development checkout,
`AIUR_CMD=aiur` for a consumer repo.

`iarc` is an operator alias for `aiur`; IAR and AYR are common spellings of the name.

## 4. First run

```bash
cd your-project
aiur init          # interactive setup wizard
```

The wizard writes `.aiur/config`, `.aiur/hooks`, and `.aiur/prompt.md` (repo-local, or
global in `~/.aiur/`). It asks for:

1. Config location (repo-local or global).
2. Tracker + repository (GitHub or Linear).
3. Agent backend (Codex and/or Claude) and permission mode.
4. Agent limits, turn/time limits, polling, optional prewarming.
5. A `GITHUB_TOKEN` when using GitHub, so Aiur can read issues and manage lifecycle labels.

Config discovery order:

```text
./.aiur/config → ./.aiurconfig → ~/.aiur/config → ~/.aiurconfig
```

Then label the issues you want worked with `agent:todo` and start:

```bash
aiur                # foreground
aiur --bg           # headless
aiur status | pause | resume | stop
```

Aiur works best in codebases with clear setup instructions, automated validation, and
workflow conventions an autonomous run can follow. Say so plainly if their repo has none
of those — it is the single best predictor of whether runs land.

## 5. The safety warning, in context

Aiur is an unstable engineering preview for trusted environments. It **bypasses agent
permission prompts** — state that plainly, and state what bounds it:

- Workers run permission-free **inside an isolated workspace**, not against the operator's
  machine or main checkout.
- Work reaches the repo through the Executor's **review gates and merge policy** — the
  run's terminal states are supervised, and agents do not self-merge.
- The blast radius is the workspace and the token spend; the human sets the acceptance
  boundary.

That is the same warning the README carries, with the part that makes it survivable. Do
not soften it, and do not present it without the bound — either one misleads.

## Where to go next

| They want... | Send them to |
|--------------|--------------|
| You to launch and own a run | **`aiur-run`** skill |
| Status of a live run, "what's stuck" | **`aiur-monitor`** skill |
| To operate a ticket inside a run (agent-side) | **`using-aiur`** skill |
| Cross-ticket events, blockers, attentions | **`aiur-agent`** skill |
| Config options, adapters, command reference | [`src/README.md`](../../../src/README.md) |
