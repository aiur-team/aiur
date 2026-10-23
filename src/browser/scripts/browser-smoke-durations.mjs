// Recorded browser smoke suite durations in seconds: the slowest of 11 ci runs on main and merge_group
// (2026-10-18, runs 39094806634..39100789804). check-browser-smoke-shards.mjs sums them per shard
// and fails when a shard passes 75% of its budget or runs a suite missing here. Refresh from a shard log's
// "suite durations" lines when a suite grows or a new one lands.
// The shard runner runs `fixture:preflight` (mix compile) before its suites, inside the same deadline;
// run 39100789804 spent 80-120s per shard outside its suites.
export const preflightSeconds = 120
export const recordedSeconds = {
  // CI run 39616972873 (2026-10-21), jobs 119280971812/119280971969:
  // document functional 43.8s and parity 150.5s suite wall time, rounded up.
  'test:build-home-modal-doc': 44,
  'test:build-home-modal-doc-parity': 151,
  // Governed local run (2026-10-21): all 13 nav cells passed in 151.44s;
  // conservative measured 200s wrapper wall bound includes gate wait/startup.
  'test:cutover-nav-parity': 200,
  // Green PR #5016 CI run 39273221105, head 6ed6d40de039efe1efedc30e9948090ec98a0881.
  // Whole-command wall times from completed shard logs, rounded up (not test-time sums).
  // Job 118131038618 (shard 8/9): 0.5s.
  'test:build-home-chains-unit': 1,
  // Job 118131038618 (shard 8/9): 132.3s.
  'test:build-home-chains': 133,
  // Job 118131038704 (shard 7/9): 126.4s.
  'test:build-home-chains-parity': 127,
  'test:browser-suite -- build-home-composer': 23.3,
  // Job 118131038510 (shard 2/9): 28.7s.
  'test:browser-suite -- build-home-chains-states': 29,
  // CI run 39590874795 (2026-10-21), full suite wall times including fixture startup:
  // shards 5/8/7 measured modal 30.9s, parity 122.8s, motion 25.6s; round each up.
  'test:build-modal': 31,
  'test:build-modal-parity': 123,
  'test:build-modal-motion': 26,
  // Same run, shard 7/job 119192841077: all 14 conversation cases passed; 163.6s wall time.
  'test:build-home-conversation': 165,
  // Governed core commands (2026-10-18): 31 cases in 518s; 32 cases on 2ed995a67 in 445s.
  // Keep the slower observed bound; wall timings include fixture startup and build-gate wait.
  'test:build-home-gantt': 518,
  // CI run39148293958 (d9ee8e071), job117736821220: actual suite wall seconds.
  'test:build-home-now-band': 44.7,
  'test:browser-suite -- build-home-live-button-parity': 52.7,
  // Conservative CI-measured full-selection bounds from review5564161995 (#5124).
  // Routine commands select fewer cells; these are NOT routine measurements.
  // Refresh with routine suite-duration logs after the first new-head CI run.
  'test:build-home-band-parity': 303,
  'test:build-home-band-motion': 280,
  // PR #4805 suite-duration logs (2026-10-18): units/browser from run 39093008001 at ea5f25e39.
  // Parity uses the latest green run 39093008001 at ea5f25e39 (102.5s).
  'test:build-home-edges-unit': 0.2,
  'test:build-home-edges': 111.4,
  'test:build-home-edges-parity': 102.5,
  'test:home-css-ci': 5,
  'test:admission': 1,
  'check:elk': 1,
  // Same run, shard 3/job 119192840906: 26 exporter tests + 29 URL goldens; 29.2s wall time.
  'check:build-home-fixtures': 30,
  'test:build-home-protocol': 1,
  'test:build-home-now-state': 1,
  'test:harness': 7,
  'test:smoke': 18,
  'test:command-answer': 20,
  'test:build-index-live': 20,
  'test:build-home-assets': 14,
  'test:build-home-layout': 33,
  'test:shell': 34,
  'test:shell-chrome': 37,
  'test:shell-width': 62,
  'test:command-history': 15,
  'test:build-order': 25,
  'test:build-queue': 16,
  'test:experiments': 15,
  'test:interaction': 26,
  'test:time-brush': 8,
  'test:performance': 18,
  'test:responsive': 16,
  'test:layout': 24,
  'test:ticket-context': 17,
  'test:units': 38,
  'test:provider-meters': 14,
  'test:meter-row': 15,
  'test:models-panel': 9,
  'test:quota-panel': 8,
  'test:parity': 16,
  'test:streamdeck': 59,
  'test:streamdeck-flow': 13,
  'test:design-parity': 178,
  'test:palette': 16,
  'test:tokens': 27,
  'test:shell-parity': 169,
  'test:build-home': 89,
  'test:build-home-motion': 508,
  'test:build-home-offline': 12,
  'test:build-home-render': 190,
  'test:build-home-columns': 636,
  'test:build-home-tools': 289,
  'test:build-home-span': 22,
  'test:build-home-span-parity': 207,
  'test:build-home-cards:1': 133,
  'test:build-home-cards:2': 269,
  'test:build-home-cards:3': 220,
  'test:build-home-cards:4': 298,
  'test:build-home-states-parity': 200,
  'test:build-home-list-unit': 1,
  // Usage: CI job 117605146944 reported 268.0s; round up conservatively.
  'test:build-home-usage': 269,
  // Run 39091360816, job 117578322274: agents took 21.8s (rounded up).
  'test:browser-suite -- build-home-agents': 22,
  'test:browser-suite -- build-home-list': 26,
  'test:browser-suite -- build-home-list-parity': 57,
  'test:browser-suite -- build-home-mobile-fit': 12,
  'test:browser-suite -- build-home-states': 9,
  'test:browser-suite -- build-home-states-e2e': 15,
}
