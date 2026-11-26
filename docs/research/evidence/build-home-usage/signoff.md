# Usage strip sign-off evidence (S-50)

Owner approval is pending. Issue #3155 implements the adopted defaults for states absent from the reference design.

Product screenshots are committed in [the browser snapshot folder](../../../../src/browser/tests/build-home-usage.browser.spec.mjs-snapshots/). The `edge state screenshots for S-50 owner sign-off` browser test regenerates and checks them at the harness viewport.

| Screenshot | Decision to review |
| --- | --- |
| `usage-unknown-linux.png` | Unknown values use dashed segments and an explicit unknown reset. |
| `usage-partial-linux.png` | The mean includes known accounts only; the unknown account retains its own segment. |
| `usage-none-linux.png` | Unobserved and retained stale notes remain visible through the popover. |
| `usage-credits-linux.png` | An unknown credit amount uses neutral text rather than the money style. |
| `usage-onewin-linux.png` | Missing windows are omitted; a row with neither window says not observed. |
| `usage-stale-linux.png` | Stale readings are dimmed; observation age is included in the popover. |
| `usage-ended-linux.png` | An expired reset says window ended rather than freezing its countdown. |
| `usage-hold-linux.png` | GitHub holds appear in the popover. |
| `usage-locked-linux.png` | One status card replaces all financial values. |
| `usage-unavailable-linux.png` | One status card names source failure without displaying values. |
| `usage-hostile-linux.png` | Payload markup is displayed as literal text. |
| `usage-empty-linux.png` | Empty provider and API lists have explicit copy. |
| `usage-one-linux.png` | Counts use singular forms; the model counter is inert. |

The parity spec compares 2, 4 and 7 providers at 1440, 1024 and 390 pixel viewports in both themes and palettes. Separate popover records cover opacity and transform; grain records cover both themes. The parity allowlist records the counter cursor and removed demo title as pending sign-off.

Usage lines receive keyboard focus and expose their complete tooltip as an accessible name. The final focus-ring and phone redesign remain owned by C12-T05 and C12-T04. Executor-root manual CLI verification remains outstanding; these are automated browser artifacts.
