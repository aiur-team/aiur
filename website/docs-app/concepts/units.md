# Units

A Unit is one agent run working one ticket while it is active, paused, or waiting.

Use `aiur units` to inspect the fleet. The former dashboard Units board has
been retired; `/units` redirects permanently to `/`, preserving its query.
The [Build page](/concepts/build-history) is the dashboard home.

Paused agents remain listed. Only pauses that reserve capacity count as occupied
slots; a provider usage-limit pause releases its slot while it waits.

Use `aiur set max-agents <n>` to adjust fleet capacity and
`aiur --todo <ticket-id>` to queue a ticket. The retired board's routing preview,
Add an agent panel and run-summary strip are no longer dashboard controls.

Worker conversation voice controls and the Executor prototype remain available
from **Settings → Talk to Executor** (`/voice`). Open a ticket on Build to read its conversation or
send a message.

The CLI supports `--scope live|unfinished|all|none` and repeated `--condition`
filters. Context occupancy and Aiur orchestration turns remain separate from
cumulative token usage. Missing or unsupported measurements remain unavailable.

See the [CLI reference](/reference/cli) for inspection and control commands.
