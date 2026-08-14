# Stream Deck

Open `/streamdeck` in the [Dashboard](/guide/executor-control-center) to use the browser emulator, or install the physical Stream Deck + sidecar. Both surfaces use the same projected fleet and AgentChat control contract.

The browser emulator has three modes. A key press changes more than the key grid: it also changes the touch strip and dial actions. Treat the dial labels as current-mode controls, not as persistent settings.

## Drive the three modes

| Mode | Enter it | Keys | Touch strip | Dials A–D |
| --- | --- | --- | --- | --- |
| **Grid** | The initial view; press an agent key to select it. | Up to eight agent keys. | Fleet summary, provider-meter segments, and the page indicator. | **A (Focus):** Back; it has nowhere to go at the top level. **B (Volume):** on the physical deck, turn to scroll the merged provider panel when more providers are configured than it shows at once — the panel says so with a chevron on the side that still has providers; unassigned in the browser emulator. **C (Speed):** unassigned. **D (Page):** turn to page the agent columns; press to cycle the next agent window. |
| **Command** | Press an agent key in Grid. | Pause/Play, Prioritize/Deprioritize, Logs, and Mic; the other four slots are blank. | The selected agent’s provider, status, and progress. | **A:** return to Grid. **B/C:** unassigned. **D:** press to open Logs; turning it has no command-mode action. |
| **Logs** | Press **Logs**, or press dial D in Command mode. | The live marker and up to seven event keys for the selected agent. | The two-line transcript window for the selected event. | **A:** turn to scroll the transcript and press to return to Command. **B/C:** unassigned. **D:** turn to scroll the event-key window; its press does not add another mode. |

The `Pause` and `Prioritize` labels reflect the selected agent’s actual current state. In a read-only Dashboard those mutating controls are disabled. **Mic is press-and-hold, not a click:** it is active only while held and clears on release, cancellation, or leaving the key.

In Logs mode, click an event key to select it. That does not merely highlight the key: it moves the touch strip to the selected event’s position in the flattened transcript. Dial A then continues from that position; dial D changes which event keys are visible.

## How Grid chooses agent keys

Grid has five buckets, in this exact priority: `alert` → `stuck` → `running` → `paused` → `queued`. Within `queued`, dependency-ready (unblocked) agents precede blocked agents. The server supplies that already-ranked list; the surface does not re-sort it.

The eight key slots are column-major, not the usual row-major order. The first column contains agents 1 and 2, the next contains 3 and 4, and so on. Paging moves by columns, so a column’s pair stays together as you turn or press dial D.

## Physical sidecar status

The commit-addressed Linux x64 archive installs the bundled Node runtime, the direct-HID sidecar and its production dependencies, a systemd **user** service, and the udev rule required to access the device. The supported transport deployment is Arch Linux on x64 glibc 2.28+; it does not support Alpine/musl, ARM, or older glibc.

The service opens the USB device, sends a key-stream reset, applies `STREAMDECK_BRIGHTNESS`, watches hotplug and suspend, and connects to the authenticated Phoenix channel. It receives live fleet/provider projections, paints the key/touch-strip surface, and routes physical key controls through AgentChat. A short-lived token is renewed after channel disconnects.

Set `AIUR_PHOENIX_URL`, `AIUR_DASHBOARD_USERNAME`, and `AIUR_DASHBOARD_PASSWORD` in the private sidecar environment file at `~/.config/aiur/streamdeck.env`. The password is used only to mint the short-lived channel token and is not placed in the WebSocket URL. A Stream Deck +, an Arch Linux graphical session with systemd/logind, and the `users` fallback ACL are required for the physical surface.

The [direct-HID transport runbook](https://github.com/aiur-team/aiur/blob/develop/packages/streamdeck/README.md) covers the archive, device access, pairing, and recovery workflow. [#1358](https://github.com/aiur-team/aiur/issues/1358) remains the terminal end-to-end evidence ticket for the physical surface.

## Shared key-face contract

The browser emulator and the sidecar package share a data-only key-face contract for bucket rank, labels, colours, progress hue, log direction badges, and queued-agent readiness. Parity vectors verify those renderer building blocks, and a missing or non-true queued readiness flag fails closed as **Blocked**, rather than displaying a guessed “Unblocked” state.

That code-level contract is now composed with the live channel and HID runtime. It is still not a substitute for the required Executor-root hardware proof.
