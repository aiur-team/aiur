# Stream Deck

Open `/streamdeck` in the [Dashboard](/guide/executor-control-center) to use the browser emulator. It is the current live operator control surface: select an agent in the grid, use its controls, and inspect its recent event feed without leaving the fleet view. A physical Stream Deck + is **not yet** a live fleet controller; see [Physical sidecar status](#physical-sidecar-status).

The browser emulator has three modes. A key press changes more than the key grid: it also changes the touch strip and dial actions. Treat the dial labels as current-mode controls, not as persistent settings.

## Drive the three modes

| Mode | Enter it | Keys | Touch strip | Dials A–D |
| --- | --- | --- | --- | --- |
| **Grid** | The initial view; press an agent key to select it. | Up to eight agent keys. | Fleet summary, provider-meter segments, and the page indicator. | **A (Focus):** Back; it has nowhere to go at the top level. **B (Volume)** and **C (Speed):** unassigned. **D (Page):** turn to page the agent columns; press to cycle the next agent window. |
| **Command** | Press an agent key in Grid. | Pause/Play, Prioritize/Deprioritize, Logs, and Mic; the other four slots are blank. | The selected agent’s provider, status, and progress. | **A:** return to Grid. **B/C:** unassigned. **D:** press to open Logs; turning it has no command-mode action. |
| **Logs** | Press **Logs**, or press dial D in Command mode. | The live marker and up to seven event keys for the selected agent. | The two-line transcript window for the selected event. | **A:** turn to scroll the transcript and press to return to Command. **B/C:** unassigned. **D:** turn to scroll the event-key window; its press does not add another mode. |

The `Pause` and `Prioritize` labels reflect the selected agent’s actual current state. In a read-only Dashboard those mutating controls are disabled. **Mic is press-and-hold, not a click:** it is active only while held and clears on release, cancellation, or leaving the key.

In Logs mode, click an event key to select it. That does not merely highlight the key: it moves the touch strip to the selected event’s position in the flattened transcript. Dial A then continues from that position; dial D changes which event keys are visible.

## How Grid chooses agent keys

Grid has five buckets, in this exact priority: `alert` → `stuck` → `running` → `paused` → `queued`. Within `queued`, dependency-ready (unblocked) agents precede blocked agents. The server supplies that already-ranked list; the surface does not re-sort it.

The eight key slots are column-major, not the usual row-major order. The first column contains agents 1 and 2, the next contains 3 and 4, and so on. Paging moves by columns, so a column’s pair stays together as you turn or press dial D.

## Physical sidecar status

The commit-addressed Linux x64 archive installs the bundled Node runtime, the direct-HID sidecar and its production dependencies, a systemd **user** service, and the udev rule required to access the device. The supported transport deployment is Arch Linux on x64 glibc 2.28+; it does not support Alpine/musl, ARM, or older glibc.

That service currently owns only device lifecycle: it opens the USB device, sends a key-stream reset, applies `STREAMDECK_BRIGHTNESS`, and watches hotplug and suspend. Its production entry point does not connect to a daemon or Phoenix endpoint and supplies neither the `onInput` nor `repaint` hook. It therefore cannot receive live fleet state, paint the keys or touch strip, or send an agent control.

Do not treat setting `AIUR_PHOENIX_URL` or Dashboard Basic Auth values in `~/.config/aiur/streamdeck.env` as pairing: the current production entry point does not consume them. A Stream Deck +, an Arch Linux graphical session with systemd/logind, and the `users` fallback ACL are prerequisites only for testing the direct-HID service lifecycle—not for operating Aiur from the device. Use the browser emulator for all fleet controls.

The [direct-HID transport runbook](https://github.com/aiur-team/aiur/blob/develop/packages/streamdeck/README.md) covers the archive, device access, and lifecycle-only service. The missing live-device composition needs separate implementation; [#1358](https://github.com/aiur-team/aiur/issues/1358) is its terminal end-to-end evidence ticket. Once the composition is implemented and proven, this guide can document the physical pairing and recovery workflow without promising unavailable behavior.

## Shared key-face contract

The browser emulator and the sidecar package share a data-only key-face contract for bucket rank, labels, colours, progress hue, log direction badges, and queued-agent readiness. Parity vectors verify those renderer building blocks, and a missing or non-true queued readiness flag fails closed as **Blocked**, rather than displaying a guessed “Unblocked” state.

That code-level contract is not live-device proof: the production sidecar does not yet compose its renderer with fleet transport or input handling. It must not be read as a claim that the browser emulator and a physical deck currently render or control the same fleet.
