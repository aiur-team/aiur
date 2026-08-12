# Stream Deck

Open `/streamdeck` in the [Dashboard](/guide/executor-control-center) to use the browser emulator. It is the operator-facing counterpart to the Stream Deck + sidecar: select an agent in the grid, use its controls, and inspect its recent event feed without leaving the fleet view.

The surface has three modes. A key press changes more than the key grid: it also changes the touch strip and dial actions. Treat the labels on the physical dials as the current-mode controls, not as persistent settings.

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

The eight physical slots are column-major, not the usual row-major order. The first column contains agents 1 and 2, the next contains 3 and 4, and so on. Paging moves by columns, so a column’s pair stays together as you turn or press dial D.

## Install the downloadable sidecar

The commit-addressed Linux x64 archive installs the bundled Node runtime, the Stream Deck sidecar and its production dependencies, a systemd **user** service, and the udev rule required to access the device. The supported deployment is Arch Linux on x64 glibc 2.28+; it does not support Alpine/musl, ARM, or older glibc.

You need a Stream Deck + connected over USB, an Arch Linux graphical user session with systemd/logind, the `users` group fallback ACL, and a reachable Aiur Dashboard. Install the archive, its udev rule, and the user unit; then pair the sidecar by creating `~/.config/aiur/streamdeck.env` with the Dashboard URL and its Basic Auth credentials. Keep that file mode `600`, reload the udev rules, physically replug the deck, and enable `aiur-streamdeck.service`.

The full, copyable install, pairing, checksum, permission, hotplug, and recovery procedure is in the [Stream Deck sidecar runbook](https://github.com/aiur-team/aiur/blob/develop/packages/streamdeck/README.md). The Dashboard’s **Install +** control opens the same pairing checklist.

## One visual contract, two renderers

The browser emulator renders HTML/CSS; the sidecar renders device bitmaps. They consume one data-only key-face contract for bucket rank, labels, colours, progress hue, log direction badges, and queued-agent readiness. That shared contract deliberately does not share drawing code: each medium renders it appropriately.

There is no silent fallback when the two sides drift. The parity vectors exercise both renderers, and an added state or badge that one renderer has not handled fails the contract checks. A missing or non-true queued readiness flag also fails closed as **Blocked**, rather than displaying a guessed “Unblocked” state.
