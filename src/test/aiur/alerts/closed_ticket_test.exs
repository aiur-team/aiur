defmodule Aiur.Alerts.ClosedTicketTest do
  use ExUnit.Case, async: false

  alias Aiur.{AlertFeed, AlertLedger}
  alias Aiur.Alerts.ClosedTicket
  alias Aiur.Orchestrator.WorkspaceCleanup

  setup do
    root = Aiur.TestSupport.tmp_root!("aiur-closed-ticket")
    File.mkdir_p!(root)
    previous = Application.get_env(:aiur, :runtime_state_dir)
    Application.put_env(:aiur, :runtime_state_dir, root)

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :runtime_state_dir, previous), else: Application.delete_env(:aiur, :runtime_state_dir)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    ledger = AlertLedger.path()
    assert String.starts_with?(ledger, root)

    for topic <- [
          "ticket.10.agent.attention.merge_terminal_write_failed",
          "ticket.10.merge.attribution_check_failed",
          "ticket.100.agent.attention.operator-decision",
          "system.github.rate_limited"
        ] do
      :ok = AlertLedger.append(%{"timestamp" => "2026-10-01T00:00:00Z", "topic" => topic, "needs_attention" => true})
    end

    %{ledger: ledger}
  end

  test "resolves every open attention of a closed ticket and nothing else", %{ledger: ledger} do
    assert :ok = ClosedTicket.resolve(["10"], ledger_path: ledger)
    assert open_topics(ledger) == ["system.github.rate_limited", "ticket.100.agent.attention.operator-decision"]
  end

  test "terminal workspace cleanup resolves the closed ticket's attentions", %{ledger: ledger} do
    # A non-binary workspace identifier fails the workspace entry fast; the
    # attentions are resolved before any entry runs.
    assert :ok = WorkspaceCleanup.start_terminal_workspace_cleanups([{"10", :not_a_leaf, nil}])
    assert_receive {:workspace_cleanup_finished, :not_a_leaf, {:error, _message}}, 10_000
    assert open_topics(ledger) == ["system.github.rate_limited", "ticket.100.agent.attention.operator-decision"]
  end

  defp open_topics(ledger) do
    [ledger_path: ledger, needs_attention: true] |> AlertFeed.list() |> Enum.map(& &1["topic"]) |> Enum.sort()
  end
end
