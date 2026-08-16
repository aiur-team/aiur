# Pre-existing dialyzer warnings inherited from main (PR #96 opencode
# pre-warm refactor + earlier). Logged here to unblock CI; each entry
# should be removed by a follow-up dedicated to fixing the underlying
# type discrepancy.
[
  # `pattern_match_cov` / `pattern_match`: legacy clauses dialyzer can prove
  # unreachable from the inferred call sites.
  {"lib/aiur/agent_list/app.ex"},
  {"lib/aiur/http_server.ex", :pattern_match_cov},
  {"lib/aiur/opencode/slot.ex", :pattern_match_cov},

  # `call_with_opaque` / `call_without_opaque`: MapSet/Map opaque-type
  # interop. The runtime works; dialyzer's opaque tracking gets confused.
  {"lib/aiur/github/code_owners.ex", :call_without_opaque},
  {"lib/aiur/github/issue_dependencies.ex", :call_with_opaque},
  {"lib/aiur/orchestrator/lifecycle.ex", :call_without_opaque},
  {"lib/aiur_web/build_order_presenter.ex", :call_without_opaque},
  {"lib/aiur_web/components/operator_control_center/build_order_breakdown.ex",
   :call_without_opaque},
  {"lib/aiur_web/operator_control_center/usage_summary_presenter.ex", :call_without_opaque},

  # Guardian liveness comes from injectable OS probes. Dialyzer collapses the
  # default `kill -0` probe to `true`, although the explicit false branch is
  # exercised by the process-containment regression tests.
  {"lib/aiur/workspace/ownership/guardian.ex", :pattern_match},

  # `Mint.WebSocket.new/4` succeeds only on a 101, which its own private
  # `do_new(:http1, conn, status, _) when status != 101` clause expresses as a
  # guard on a runtime value. Dialyzer cannot see that our status *is* 101 by
  # then, so it decides the `{:ok, conn, websocket}` branch is unreachable and
  # types the call as error-only. Declaring the state and the fold accumulator
  # (see the types in that module) did not move it, because the fold runs
  # through `Enum.reduce_while/3` and its return type is opaque.
  #
  # The success branch is demonstrably reached: `mint_socket_test.exs` completes
  # a real RFC 6455 handshake on loopback and receives frames through it, and
  # the `:external` latency test transcribes live speech end to end. Remove this
  # entry if a future mint_web_socket makes the 101 check expressible in types.
  {"lib/aiur/eleven_labs/realtime/mint_socket.ex", :pattern_match}
]
