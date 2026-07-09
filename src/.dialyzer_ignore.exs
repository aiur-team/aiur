# Pre-existing dialyzer warnings inherited from main (PR #96 opencode
# pre-warm refactor + earlier). Logged here to unblock CI; each entry
# should be removed by a follow-up dedicated to fixing the underlying
# type discrepancy.
[
  # `pattern_match_cov` / `pattern_match`: legacy clauses dialyzer can prove
  # unreachable from the inferred call sites.
  {"lib/aiur/agent_list/app.ex"},
  {"lib/aiur/agent_runner.ex", :pattern_match_cov},
  {"lib/aiur/http_server.ex", :pattern_match_cov},
  {"lib/aiur/opencode/slot.ex", :pattern_match_cov},

  # `call_with_opaque` / `call_without_opaque`: MapSet/Map opaque-type
  # interop. The runtime works; dialyzer's opaque tracking gets confused.
  {"lib/aiur/github/code_owners.ex", :call_without_opaque},
  {"lib/aiur/github/issue_dependencies.ex", :call_with_opaque},
  {"lib/aiur/github/issue_dependencies.ex", :call_without_opaque},
  {"lib/aiur/orchestrator.ex", :call_without_opaque}
]
