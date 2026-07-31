# Stream Deck bucket design tokens

Source: `docs/build-order/prototype/Aiur Operator Control Center.html`

## Accent colours

Mapped from the OCC CSS custom properties (dark-mode values):

| Bucket  | Accent    | OCC var        | OCC value  |
|---------|-----------|----------------|------------|
| running | `#4fd6c4` | `--ack`        | `#4fd6c4`  |
| paused  | `#8fbcff` | `--accent-ink` | `#8fbcff`  |
| stuck   | `#e3b341` | `--attn`       | `#e3b341`  |
| alert   | `#ff7b72` | `--block`      | `#ff7b72`  |
| queued  | `#c69bff` | `--super`      | `#c69bff`  |

## Glow colours (outer ring)

Same RGB as each bucket's accent, at a higher opacity than the OCC web soft
variants (`--*-soft` are 0.14–0.15) so the glow reads on the physical device's
backlit display. Opacity values are in the 0.32–0.40 range used consistently
across the stream deck emulator prototypes.

| Bucket  | Glow                      | Derived from accent RGB |
|---------|---------------------------|-------------------------|
| running | `rgba(79,214,196,0.35)`   | `#4fd6c4` at α=0.35     |
| paused  | `rgba(143,188,255,0.32)`  | `#8fbcff` at α=0.32     |
| stuck   | `rgba(227,179,65,0.38)`   | `#e3b341` at α=0.38     |
| alert   | `rgba(255,123,114,0.40)`  | `#ff7b72` at α=0.40     |
| queued  | `rgba(198,155,255,0.32)`  | `#c69bff` at α=0.32     |

## Face colours (inner gradient base)

Dark tinted surfaces: the OCC base background `--bg: #16171a` tinted with each
bucket's accent at approximately 8–10% intensity, producing a near-black with a
hue cast that matches the bucket.

| Bucket  | Face      | Hue cast |
|---------|-----------|----------|
| running | `#112524` | teal     |
| paused  | `#142035` | blue     |
| stuck   | `#2a2112` | amber    |
| alert   | `#2d1718` | red      |
| queued  | `#20172f` | purple   |

## Pulse durations

`stuck` and `alert` pulse to signal that the agent requires operator attention.
The OCC prototype uses a 1.6 s pulse period for attention-state indicators
(`.ls-step.current .lsn-dot`, line 613 of the prototype HTML). The stream deck
uses:

| Bucket | Duration | Rationale                                             |
|--------|----------|-------------------------------------------------------|
| stuck  | 1.4 s    | Faster pulse — stuck is recoverable but urgent        |
| alert  | 1.6 s    | Matches the OCC attention-state animation period      |

## Labels

| Bucket  | Label     |
|---------|-----------|
| running | `Running` |
| paused  | `Paused`  |
| stuck   | `Stuck`   |
| alert   | `Alert`   |
| queued  | `Queued`  |
