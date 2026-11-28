# Units

A Unit is one agent run working one ticket while it is active, paused, or waiting.

Use `aiur units` to inspect the fleet. The former dashboard Units board has
been retired; `/units` redirects permanently to `/`, preserving its query.
The [Build page](/concepts/build-history) is the dashboard home.

Paused agents remain listed. Only pauses that reserve capacity count as occupied
slots; operator-decision and provider usage-limit waits release their slots while
they wait. `aiur status` reports long-held paused reservations and raises an
attention when one has lasted 30 minutes.

Use `aiur set max-agents <n>` to adjust fleet capacity and
`aiur --todo <ticket-id>` to queue a ticket. The retired board's routing preview,
Add an agent panel and run-summary strip are no longer dashboard controls.

Worker conversation voice controls and the Executor prototype remain available
from **Settings → Talk to Executor** (`/voice`). Open a ticket on Build to read its conversation or
send a message.

The CLI supports `--scope live|unfinished|all|none` and repeated `--condition`
filters. Context occupancy and Aiur orchestration turns remain separate from
cumulative token usage. Missing or unsupported measurements remain unavailable.

Dictation on the retained voice surface stops at the five-minute session limit
with an explanation and keeps the text for review.

See the [CLI reference](/reference/cli) for inspection and control commands.
