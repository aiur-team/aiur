# Stream Deck end-to-end proof

This is the operator runbook and evidence index for issue [#1358](https://github.com/aiur-team/aiur/issues/1358).
It is intentionally separate from the implementation tickets: a green unit or
browser test does not prove that the emulator, dashboard, and live fleet agree
while an operator drives the control surface.

## Proof boundary

Run the emulator proof only from the Executor repository root, on the final
merged Stream Deck state. An issue workspace must not run
`scripts/aiurdev --test`; the repository's `AGENTS.md` documents the required wrapper-tmux
procedure for driving the real TUI.

Before starting, record the following in the evidence directory:

```text
aiur commit: <40-character SHA>
sidecar version: <version or N/A for emulator-only proof>
kernel: <uname -r>
browser/package commit: <SHA if different from aiur commit>
run started: <ISO-8601 timestamp>
```

Use a sanitized directory such as `docs/research/evidence/streamdeck/<run-id>/`.
Do not include credentials, tokens, private issue text, raw provider responses,
agent transcripts, serial numbers, or machine-local paths in committed or
attached evidence.

## Emulator setup

From the Executor repository root:

1. Confirm the final Stream Deck tickets are merged and that `packages/streamdeck`
   is present.
2. Install and verify the package dependencies:

   ```bash
   cd packages/streamdeck
   npm ci
   npm run lint
   npm test
   npm run build
   cd ../..
   ```

3. Launch the real foreground CLI with the fixture fleet:

   ```bash
   scripts/aiurdev --test --force --allow-remote
   ```

4. Open the dashboard and `/streamdeck` in a browser. Keep the Units page
   (`/`) available in another tab or window so each fleet comparison is made
   against the same run. Capture a screenshot before interaction and after
   every state-changing step.

The `--test` run is a real CLI/TUI run, not a substitute fixture or direct HTTP
call. Send any agent-control action through the visible emulator control and
confirm it independently in both the dashboard and `aiurdev status`.

## Emulator acceptance steps

Record one screenshot or short recording per row. The suggested filenames are
stable enough to make an attached evidence set auditable; add the actual
timestamp and run id to each file.

| # | Action | Pass condition | Evidence |
|---:|---|---|---|
| 1 | Start Aiur with the fixture fleet and open `/streamdeck`. | The route loads with live agent keys and no fixture-only placeholder identity. | `01-start.png` |
| 2 | Compare the Stream Deck grid with Units for the same fleet. | Agent membership, bucket, canonical sort, provider, status, and priority agree. Repeat after a fleet update. | `02-grid-units-parity.png`, `02-grid-update.mp4` |
| 3 | Page with dial D using drag, wheel, and keyboard input; press D to cycle windows. | Each input changes the same page state; pager dots move to the selected window and never show an impossible page. | `03-paging.png`, `03-paging-inputs.mp4` |
| 4 | Press an agent key, pause it, then resume it. | The key enters command mode; pause is reflected by the key, dashboard, and `aiurdev status`; resume returns the live state. | `04-pause-dashboard-status.png`, `04-resume.png` |
| 5 | Enter logs mode. Scroll events with dial D and the transcript with dial A. | Event/transcript windows move only within real bounds and the hint arrows correctly enable/disable at both ends. | `05-logs-bounds.mp4` |
| 6 | Press dial A to back out from logs to command mode, then to grid. | The mode sequence is exactly `logs → cmd → grid`; the focused agent and page are not silently replaced. | `06-back-navigation.png` |
| 7 | Inspect the touch strip Summary, Claude, and Codex segments. | Summary counts are live; provider segments show the same real usage values as the dashboard header meters. | `07-touch-strip-dashboard.png`, `07-usage-update.mp4` |

For step 4, keep the dashboard and `aiurdev status` visible in the same frame
or capture them at the same timestamp. For steps 2 and 7, record the values
being compared in a small text file next to the screenshots; the screenshot
alone should not require guessing which agent or meter was checked.

## Browser coverage audit

Run the targeted streamdeck browser spec (added by #1353) from `src/browser`:

```bash
cd src/browser
node scripts/run-browser-tests.mjs tests/streamdeck-emulator.browser.spec.mjs
```

Then run the full suite to confirm nothing regressed:

```bash
npm test
```

Inspect the test list to verify which workflow steps are covered:

```bash
rg -n -i 'streamdeck|stream deck|dial|pager|logs mode|pause|resume' \
  tests ../test/aiur_web
```

**Known coverage state on the current merged Stream Deck surface:**

| Step | Headless coverage |
|------|-------------------|
| 2 | Grid fleet display / bucketing | The browser fixture covers live grid projection and paging, and a regression asserts the emulator's rendered key membership and column-major slot order match the Units page after a live fleet-size change. Bucket-class parity with Units is not compared headlessly and remains part of the live proof |
| 3 | Dial D paging — wheel + pager dots | Covered by `streamdeck-emulator.browser.spec.mjs` (wheel pages the fleet, pager dots follow) |
| 3 | Dial D paging — drag / keyboard; press D to cycle windows | Covered by `streamdeck-emulator.browser.spec.mjs` after the #1515 merge: the "dial D pages live fleet keys and pager dots" test asserts drag, wheel, keyboard ArrowDown, and press-D-to-cycle headlessly (page state, pager dots, and knob marker angle unchanged on press). Live proof still confirms the end-to-end driver interaction |
| 4 | Key → cmd mode; pause/resume agent | Key → cmd is covered; writable pause/resume is verified by LiveView control-boundary tests and remains part of the live proof |
| 5 | Logs mode scroll; hint arrow bounds | Covered by `streamdeck-emulator.browser.spec.mjs` (classified feed events + flattened transcript, both bounds) |
| 6 | Back-navigation logs → cmd → grid | The browser spec covers the mode sequence; focused-agent preservation across back-navigation is not asserted headlessly and remains part of the live proof |

If any of steps 2–6 still lacks a headless test when you run the proof, record
each gap as a separate non-blocking issue and link it from #1358. Do not add
unplanned test extensions to this proof ticket. The headless tests corroborate
the interaction contract; they do not replace the live-fleet screenshots in
the table above.

## Hardware applicability

Hardware steps are conditional on the result of [#1342](https://github.com/aiur-team/aiur/issues/1342).
The current #1342 spike record is a provisional architecture go but an
implementation/device-I/O no-go in
the agent sandbox: enumeration succeeded, while opening `/dev/hidraw10` did
not. It therefore does not prove LCD writes, input payloads, suspend/resume,
or Phoenix wiring.

For this acceptance run, mark steps 8–11 **N/A — #1342 no-go** unless an
Executor-root host run changes that decision and records the required device
evidence. Do not convert enumeration or library metadata into a hardware pass.

If #1342 becomes a go, run the same emulator flow through the physical deck and
record:

| # | Hardware action | Required result | Evidence |
|---:|---|---|---|
| 8 | Drive the grid, dials, keys, and strip on the physical deck. | The physical display and live dashboard remain in parity for paging, logs, pause/resume, and usage. | `08-device-flow.mp4` |
| 9 | Unplug and replug while the session is active. | The sidecar reconnects and repaints without restarting Aiur. | `09-hotplug.mp4` |
| 10 | Run `systemctl suspend`, resume, and wait for repaint. | The sidecar recovers without a process restart and the deck shows current state. | `10-suspend-resume.mp4` |
| 11 | Stop the sidecar cleanly. | The deck shows the Elgato logo, not a frozen last frame. | `11-sidecar-stop.mp4` |

Use the service and sidecar commands documented by #1357 on the final merged
state. Record the exact sidecar version and host kernel; do not run suspend or
hotplug tests on a shared host without an explicit operator-owned recovery
window.

## Completion record

The issue is ready for acceptance only when the evidence directory or attached
artifacts contains:

- all emulator artifacts `01`–`07`;
- a package CI result for `packages/streamdeck`;
- a browser coverage audit and links for any deferred findings;
- either hardware artifacts `08`–`11`, or an explicit `N/A — #1342 no-go` record;
- the recorded Aiur commit, sidecar version, kernel, and sanitized run time.

Attach the evidence index to #1358 and link any non-blocking browser or device
finding as a separate issue. Do not mark a step passed from logs, an HTTP API
response, or a unit test alone.
