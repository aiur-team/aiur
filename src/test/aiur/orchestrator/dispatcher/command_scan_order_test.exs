defmodule Aiur.Orchestrator.Dispatcher.CommandScanOrderTest do
  use Aiur.DispatcherTestSupport

  # Characterizes the pre-extraction ordering; retained as a future regression guard.
  test "command scan runs after startup-claim reconciliation and before PR-anchored stop" do
    owner = self()

    Dispatcher.dispatch_candidate_poll(%State{},
      fetch_candidate_issues_fun: fn state -> {:ok, [], state} end,
      startup_claim_opts: [
        read_boot_marker_fun: fn ->
          send(owner, :reconciled)
          {:ok, Aiur.Boot.run_id()}
        end
      ],
      scan_commands_fun: fn state ->
        send(owner, :scanned)
        state
      end,
      stop_closed_pr_agents_fun: fn state ->
        send(owner, :stopped)
        state
      end,
      stranded_reconciliation_fun: fn state, _ -> state end
    )

    assert Enum.map(1..3, fn _ ->
             receive do
               event when event in [:reconciled, :scanned, :stopped] -> event
             end
           end) == [:reconciled, :scanned, :stopped]
  end
end
