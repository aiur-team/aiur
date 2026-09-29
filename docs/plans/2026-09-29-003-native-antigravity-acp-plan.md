---
title: Native Antigravity ACP backend
type: feat
date: 2026-09-29
topic: native-antigravity-acp
artifact_contract: ce-unified-plan/v1
artifact_readiness: superseded
product_contract_source: ce-brainstorm
execution: code
---

# Native Antigravity ACP backend

## Goal Capsule

Add Google's Antigravity agent as a local Aiur backend with the session,
approval, follow-up and scoped-tool behavior expected of a native provider.
The operator installed and authenticated `agy` after Google transitioned
consumer Gemini CLI access to Antigravity. The earlier `gemini --acp` PR #2870
is a reference for Aiur's ACP plumbing, not an implementation to merge for
this operator. Aiur `v0.0.6` was already published, satisfying the original
post-release gate. The Executor continues refactor research while a background
worker implements this plan.

**2026-09-29 scope gate:** Google's current Terms §6 and FAQ prohibit using a
personal Antigravity login through third-party software and recommend Gemini
Enterprise or Google AI Studio API keys for third-party coding agents. Aiur is
third-party software. Do not use `oauth-personal` or implement a personal-login
Antigravity backend. Research whether a permitted API-key or enterprise ACP
route meets the same approval and MCP contract, then revise this plan before
implementation resumes.

**Disposition:** close this Antigravity-specific route. Continue the user's
original Gemini CLI support goal through its paid API-key/enterprise ACP path
in issue #2829 and draft PR #2870. Gemini CLI 0.61.0 locally advertises ACP
key/Vertex authentication, HTTP/SSE MCP and permission requests, but an
authenticated approval and tool round-trip remain unproved without a supported
credential. The native Gemini plan must require per-worker settings isolation
and a server allowlist because `session/new` MCP servers merge with global
Gemini settings. This document remains a record of the rejected option and
is not an implementation contract.

## Product Contract

### Summary

An operator can select `antigravity` for a local ticket. Aiur starts Google's
separately distributed Antigravity ACP server, keeps the native session bound
to that ticket, renders turns and tools, and routes each native permission
request to the Executor. Existing backends keep their current defaults.

### Key Decisions

- **Use the Google ACP server for parity.** The installed `agy` CLI's
  documented JSON stream supports turns and tool observation but handles
  headless permission requests by preset policy, without a live approval
  response. The operator chose ACP approval parity. Aiur must use the official
  `antigravity-acp` server rather than silently substitute `agy -p` or a
  third-party adapter.
- **Keep server installation and authentication explicit.** The ACP Registry
  distributes Google's proprietary `agy_acp_server` separately from `agy`.
  Aiur does not bundle it or copy the user's `agy` credentials. Missing server
  or server authentication produces actionable setup state. An authenticated
  ACP-server login through a permitted API-key or enterprise route is an
  operator prerequisite for the live wire probe; the existing personal `agy`
  login does not satisfy it. The worker must establish that the chosen route
  is supported and allowed before the plan can be marked implementation-ready.
- **Do not invent usage.** The server's token and quota fields are unverified
  for this plan. Unknown is distinct from zero, and a quota reported by a
  separate `agy` account cannot be attributed to an ACP session.
- **Preserve native approval authority.** A mutating tool waits for an
  Executor-selected ACP response. Timeout, disconnect and denial remain
  distinct. No `--dangerously-skip-permissions` fallback is allowed.

### Requirements

- R1. `antigravity` is selectable in Aiur configuration, init, routing and
  models without changing other providers' defaults or masquerading as
  enterprise Gemini CLI.
- R2. Validate the installed ACP server's protocol and capabilities before
  dispatch; report a missing, incompatible or unauthenticated server clearly.
- R3. Create a ticket-bound session, persist its exact native ID after a
  confirmed response, and load that ID on retry. Never resume “latest.”
- R4. Stream assistant text, tool calls/results and errors to the existing
  transcript and chat surfaces with truthful delivery state.
- R5. Deliver an Executor follow-up typed in Aiur's TUI to the same session
  once; support pause, stop and cancellation with confirmed or unknown
  outcomes.
- R6. Expose only attempt-scoped Aiur tools through an MCP connection whose
  capability is revoked when ownership ends. No global GitHub or supervisor
  credential enters the server or its logs.
- R7. Show a native approval request, accept only a matching Executor choice,
  and send that choice once. No implicit approval or false “approved” display.
- R8. Select only observed models and controls. Missing token, context and
  account data remain unavailable with age where a measured age exists.
- R9. Carry config, CLI, TUI, skills and usage documentation in the same PR;
  test new behavior with production-hunk red/green checks and real foreground
  TUI acceptance.

### Acceptance Examples

- AE1. An authenticated ACP server completes a ticket turn; Aiur's chat pane
  shows native prose and a tool event from that turn.
- AE2. A follow-up entered in Aiur's chat pane reaches the same session and
  renders one response; restart loads the exact stored session ID.
- AE3. A native mutating-tool approval appears in Aiur; denial blocks the
  tool, and approval allows only the correlated request.
- AE4. A ticket's MCP capability fails after revocation or when used for a
  different ticket or attempt.
- AE5. Missing server auth, unavailable usage, unsupported model and uncertain
  delivery display their real state instead of success or zero.

### Scope

Local ACP server only. The legacy Gemini CLI backend, a generic ACP framework,
automated installation of Google's binary, reading Google credential stores,
quota scraping, remote Antigravity sessions and account pricing are outside
this ticket. A later enterprise/API-key Gemini CLI option needs its own
evidence and product decision.

### Evidence and limits

- Google's [transition notice](https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli/)
  says consumer Gemini CLI requests ended on 2026-06-18, while enterprise/API
  key access remains a separate path.
- Google's [headless AGY documentation](https://www.antigravity.google/docs/cli/headless/)
  documents multi-turn `stream-json`, cumulative usage and soft denial of
  approvals that cannot be obtained in headless mode. A local authenticated
  `agy` 1.2.13 probe completed two turns; a shell-tool probe was soft-denied
  with exit zero under `request-review`.
- Google's [Terms §6](https://antigravity.google/terms) and
  [FAQ](https://www.antigravity.google/docs/faq/) explicitly prohibit personal
  Antigravity login through third-party software and recommend Gemini
  Enterprise or Google AI Studio API keys for third-party coding agents. The
  server's advertised `oauth-personal` method is not an acceptable Aiur route.
- The [ACP Registry manifest](https://github.com/agentclientprotocol/registry/blob/main/antigravity-acp/agent.json)
  names Google as publisher and lists server 1.2.1 for Linux and Darwin. A
  locally cached Linux server answered ACP `initialize` with protocol 1,
  `loadSession`, prompt/session/MCP capabilities and four auth methods.
  `session/new` returned `Authentication required`: the user's `agy` sign-in
  did not select server auth. Approval, MCP and authenticated turns remain
  unverified until that separate server is signed in.
- `docs/plans/2026-09-29-001-feat-native-gemini-cli-plan.md` on the planning
  branch and PR #2870 provide source-level ACP adaptation ideas. Their Gemini
  authentication, usage and executable assumptions must not be copied as facts.

## Planning Contract

### Technical decisions

- KTD1. Keep ACP framing and session state in Antigravity-owned adapter
  modules. Reuse PR #2870 code only where a local server probe verifies the
  same wire contract and ownership behavior.
- KTD2. Resolve the server from an explicit executable path or `PATH` and
  validate `initialize` before dispatch. Use the ACP Registry invocation for
  the installed platform: Linux x86_64 and aarch64 run
  `agy_acp_server.par --uid=`; macOS runs `agy_acp_server.par` without that
  argument. Test the same invocation in the probe and runtime. Surface the
  server's auth methods without handling credentials inside Aiur.
- KTD3. Persist a confirmed native session ID per ticket attempt. Correlate
  ACP request IDs, notifications and permission choices; do not infer delivery
  from a process write alone.
- KTD4. Bind Aiur's existing MCP gateway to the attempt. Probe Google's ACP
  MCP transport and header support before selecting HTTP or stdio; if a
  scoped secret cannot be carried safely, stop implementation at this gate.
- KTD5. Keep model and usage decoding behind the provider descriptor. First
  compare server-emitted fields with actual turns; unsupported fields remain
  unknown, not sourced from a separate CLI account or private SQLite files.

### Implementation units

1. **Probe and registration.** First determine and document the server's
   native login flow, have the operator complete it, and record authenticated `initialize`,
   `session/new`, `session/load`, model and permission wire behavior from
   server 1.2.1 in an isolated fixture workspace. Register `antigravity` in
   provider/config/init paths only after required capabilities are proved.
2. **Session and delivery.** Implement owned server process, exact-ID
   new/load, streaming prompt, follow-up, cancellation and cleanup. Test late,
   duplicate, missing and malformed frames plus uncertain process exit.
3. **Tools and approvals.** Connect ticket-scoped MCP and native permission
   request/response to existing Aiur surfaces. Prove revoke, cross-ticket
   refusal, denial, timeout and duplicate response behavior.
4. **Presentation and docs.** Normalize transcript, model and evidenced usage;
   update existing config, quick-start, TUI, provider and skill pages. Keep
   unsupported quota/remote controls explicit.
5. **Validation and landing.** Run focused tests, docs/config checks, relevant
   browser tests and required CI. For each added regression, remove its
   production hunk in a clean isolated worktree, observe red, restore and
   observe green. Independently review, fix findings, then use the real
   foreground `scripts/aiurdev --test` TUI from the Executor checkout to
   open a chat pane, send a follow-up and decide an approval. Do not run the
   harness until #2885 bounds its ticket set and the #2743 dirty-workspace
   stop-loss is safe.

### Execution gates

- The server authentication and live ACP approval/MCP probe are required
  before claiming a usable backend. A successful `agy -p` run does not satisfy
  either gate. Until the login procedure and authenticated probe are verified,
  this plan is probe-gated; implementation may prepare isolated adapter work,
  but must not claim parity or merge.
- Do not merge a provider that can stream text but cannot bind tools and
  approval authority. If Google server 1.2.1 cannot meet those contracts,
  report the exact unsupported boundary and return to product scope rather
  than silently weakening parity.
- Use an isolated worktree from latest `main`; leave the shared dirty checkout,
  Khala daemon and #2832 recovery worktree untouched.

## Definition of Done

`antigravity` can dispatch, resume, stream, receive a TUI follow-up, use
attempt-scoped tools and resolve a real native permission request through
Aiur. Required CI, mutation checks, docs and the bounded foreground TUI run
pass on the final PR head; the Executor reviews and merges it. Unavailable
usage and unsupported controls are represented honestly.
