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

Same RGB as each bucket's accent — each triple is the hex-decoded accent channel.
The alpha values (0.32–0.40) are chosen to be readable on the physical device's
backlit display; they are design constants, not derived from any other source.
The OCC web palette uses `--*-soft` variants at 0.14–0.15, which are too faint
at device brightness levels.

| Bucket  | Glow                      | Accent RGB basis                  |
|---------|---------------------------|-----------------------------------|
| running | `rgba(79,214,196,0.35)`   | `#4fd6c4` → 79,214,196, α chosen |
| paused  | `rgba(143,188,255,0.32)`  | `#8fbcff` → 143,188,255, α chosen |
| stuck   | `rgba(227,179,65,0.38)`   | `#e3b341` → 227,179,65, α chosen  |
| alert   | `rgba(255,123,114,0.40)`  | `#ff7b72` → 255,123,114, α chosen |
| queued  | `rgba(198,155,255,0.32)`  | `#c69bff` → 198,155,255, α chosen |

## Face colours (inner gradient base)

Dark surfaces chosen to give each bucket a distinct hue cast against a near-black
background. These are design constants; they are not derivable from the OCC
base background (`--bg: #16171a`) by a simple alpha-blend formula.

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
