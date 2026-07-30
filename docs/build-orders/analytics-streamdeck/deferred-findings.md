# Deferred findings ledger

Discoveries preserved without expanding the active boundary.

- Consolidation clusters in the backlog: {#1007,#1016,#1330} test-isolation
  class; {#1018,#1059} partial-failure durability; {#927,#928,#1337} knob
  coupling; {#1182,#1245} takeover slices. Not in this build order.
- Tier A defects worth a follow-on queue: #1030 #678 #619 #1231 #1041 #1028
  #1058 #852 #1313 #1329 #730 #728. #1231/#852/#1313 are Executor-owned if
  they fire mid-run (fleet-blocking).
- aiur-claude npm publish gap (1.0.0 lacks rate-limit support) — unrelated.
- No dependabot/renovate config exists (pre-existing; Renovate recommended).
- 17 legacy hardcoded text colors in dashboard.css (allowlisted by theme test).
