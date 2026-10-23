# Units

A Unit is one agent run working one ticket while it is active, paused, or waiting.

## What the Units page shows

The Units page is the hidden dashboard rollback route `/units`, retained for one release, and CLI `aiur units`. The dashboard home `/` is now Build.

<img src="/images/dashboard/units-dark.png" alt="Desktop Units fleet table with synthetic active, blocked, retrying, and review tickets">

| Column or control | Meaning |
| --- | --- |
| State filters | Cumulative `active`, `alert`, `paused`, `queued`, and `finished` conditions. |
| Unit | Agent family, model, complexity, and priority tags for the selected routing. |
| Activity | Latest action and elapsed time. |
| Commands | Durable issues the Unit raised for the Executor. |
| CI and review | Current PR facts with safe links to the ticket, Command, or conversation. |
| CLI scope | `--scope live|unfinished|all|none`; repeat `--condition` for any selected condition. |

The page re-reads the fleet on every daemon change and at least every 15 seconds. A source that answers too late shows as unavailable on its own surface; the list still loads. When the whole read fails, the page keeps the last list, shows a **Stale list** banner with its age, and replaces each elapsed time with `Stale`.

The Summary progress bar uses the daemon's weighted current-run aggregate across Units with current inputs. When that aggregate cannot be computed, the bar keeps its shape but renders as flat grey rather than as zero or a hatched track.

## Turns, context, and token usage

Each current-run Units row shows Aiur orchestration turns for the current running attempt and the provider's current context occupancy. A turn counts a distinct `session_started` event, not a model request. Context is separate from cumulative token usage.

A running unit whose backend has not reported a count or context reads **not reported**, and the tooltip names the backend. A unit with no running attempt, such as one in CI wait, reads **no attempt**.

Open a Units row's conversation to see its **Cumulative Token Usage** panel. For a running Codex agent, it uses the current attempt; otherwise it shows ticket scope.

The panel shows input, output, cached input, derived uncached input, cached proportion, scope, and observation age. Current context occupancy remains separate.

Unsupported, missing, ambiguous, or incomplete measurements remain `—`. A missing observation timestamp is labeled unknown. The panel uses Codex thread snapshots without adding the overlapping per-turn stream.

The fleet table's **Context** column shows each agent's observed context occupancy when its provider reports it. If the provider reports used tokens without a window size, the table says **unknown capacity**; an absent observation shows **—**.

## API meters

The Units strip shows non-model APIs beside model-provider meters.

| API | What the row means | Detail |
| --- | --- | --- |
| GitHub Core | REST request budget percentage used | [GitHub API budgets](/apis/github-budgets#api-budgets) |
| GitHub GraphQL | Query-point budget percentage used | [GitHub API budgets](/apis/github-budgets#api-budgets) |
| GitHub secondary limit | Active abuse-control backoff | [GitHub API budgets](/apis/github-budgets#api-budgets) |
| ElevenLabs credit quota | Account credit pool as percentage used; appears only when a key is configured | [ElevenLabs metering](/apis/elevenlabs#what-the-usage-meter-measures) |

Every meter bar runs the full width of its pane, and every progress bar on the dashboard shares the same height. Model rows show the provider logo and usage bars only — the per-provider token count, spend figure, and the ElevenLabs next-invoice amount are not rendered on the strip.

A configured meter that cannot refresh names authorization, rate-limit, or connectivity failure without exposing its credential.

An ElevenLabs account with a zero character limit renders an empty track, because there is no denominator to state a percentage against.

## Agent conversation and voice

Selecting an agent opens its live conversation without leaving Units.

| Control | Behavior |
| --- | --- |
| Composer | A writable dashboard sends typed text to the selected agent. |
| Microphone | Transcribes speech into the same composer when ElevenLabs speech-to-text is configured; the operator reviews the text and presses **Send**. |
| Waveform | Confirms the browser is receiving audio. |
| Spoken conversation | A separate half-duplex control: press, speak, press again; settled text is sent through the ordinary composer and enters the ticket transcript. |
| Spoken reply | Aiur streams ElevenLabs text-to-speech audio back to the browser when the agent replies. |
| Device selection | Browser-local and saved per dashboard origin, independent of the Stream Deck microphone preference. |

Dictation never sends a message automatically, and the browser never receives the API key.

Configure `elevenlabs.voice_id` and grant the key **Text to Speech** permission before using spoken conversation; voice cloning and barge-in are not part of this mode.

| Browser requirement | Result |
| --- | --- |
| Secure context | `localhost` qualifies; a plain-HTTP LAN address does not. |
| Remote access | Use HTTPS through a trusted private proxy. |
| Insecure origin or unsupported browser | The control is disabled with an explanation. |
| Permission denied | Explained beside the control, which stays available for a retry after a site-permission change. |

## Usage and cost

Muse allowance meters show the current and weekly windows reported by its native
CLI. These are observations from a live local host, labeled **account unverified**;
they are not account bindings or admission evidence.

The dashboard renders the observation age and marks retained readings **Stale**
after a failed refresh or when they age out; readings disappear when their host
is retired. Missing readings remain unknown, while percentages above 100% retain
their reported value (the visual bar stops at 100%).

Token usage and context capacity are separate from these allowance windows;
missing capacity or pricing is not treated as zero.

## Tickets

The Tickets panel covers every open repository ticket, including work that has not been routed to an agent.

| Surface | Behavior |
| --- | --- |
| Fleet table | Shows tickets carrying active `agent:*` labels. |
| Tickets panel | Shows identifier, title, and labels for the entire open backlog. |
| Ticket row | Opens ticket detail. |
| Robot action | Opens an editable routing preview for agent, model, effort, and complexity. |
| Confirm add-agent | Saves selected routing overrides asynchronously, adding the first active-state label only when no lifecycle state exists. The dialog closes after successful writes and reports dispatch authorization separately from scheduler admission. |
| Check admission | Rechecks an already labelled ticket without rewriting its labels. Authorization can still decline; an allowed GitHub operator must remove and reapply the trigger label using their own account. |
| Non-GitHub tracker | Reports the panel as unsupported. |

While the request runs, duplicate submission is disabled and Close stays responsive. Partial failures retain applied changes and retry only the remaining label changes. Successful label writes do not prove an agent is running: pause, prewarm, capacity, and dependency gates can still hold dispatch. See [GitHub trust](/apis/github-auth#who-aiur-trusts).

### Reveal and search

| Control | Behavior |
| --- | --- |
| Initial reveal | Shows five tickets and keeps the full count in the header. |
| Show more tickets | Adds the next batch without moving existing rows; disappears when complete. |
| Search terms | Match identifier, title, or a bounded description excerpt in any order. |
| Matching | Ignores case and punctuation; accepts prefixes and one typo. |
| Ranking | Title hits rank above description hits. |
| Scope | Searches the whole backlog, including unrevealed rows. |
| Empty result | States that nothing matched; clearing restores the full list. |

## Why Units matter

Paused, blocked, and alert rows make the reason stalled work is not advancing visible without opening a log.
