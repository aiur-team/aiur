defmodule Aiur.Alerts.ClosedTicketTest do
  use ExUnit.Case, async: true

  alias Aiur.{AlertFeed, AlertLedger}
  alias Aiur.Alerts.ClosedTicket
  alias Aiur.Orchestrator.WorkspaceCleanup

  setup do
    root = Aiur.TestSupport.tmp_root!("aiur-closed-ticket")
    File.mkdir_p!(root)
    ledger = Path.join(root, "project.alerts.ndjson")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)

    for topic <- [
          "ticket.10.agent.attention.merge_terminal_write_failed",
          "ticket.10.agent.attention.error-state-write-failed",
          "ticket.10.merge.attribution_check_failed",
          "ticket.100.agent.attention.operator-decision",
          "system.github.rate_limited"
        ] do
      :ok =
        AlertLedger.append(
          %{"timestamp" => "2026-10-01T00:00:00Z", "topic" => topic, "needs_attention" => true},
          ledger_path: ledger
        )
    end

    %{ledger: ledger}
  end

  test "resolves every open attention of a closed ticket and nothing else", %{ledger: ledger} do
    assert :ok = ClosedTicket.resolve(["10"], ledger_path: ledger)

    assert open_topics(ledger) == [
             "system.github.rate_limited",
             "ticket.10.agent.attention.error-state-write-failed",
             "ticket.10.agent.attention.merge_terminal_write_failed",
             "ticket.100.agent.attention.operator-decision"
           ]
  end

  test "system rate-limit alerts in the default ledger do not leak into this test ledger", %{
    ledger: ledger
  } do
    system_append =
      Task.async(fn ->
        AlertLedger.append(
          %{
            "timestamp" => "2026-10-02T00:00:00Z",
            "topic" => "system.github.rate_limited",
            "needs_attention" => true
          },
          ledger_path: AlertLedger.path()
        )
      end)

    assert :ok = Task.await(system_append)
    assert :ok = ClosedTicket.resolve(["10"], ledger_path: ledger)

    assert Enum.count(AlertLedger.read(ledger), &(&1["topic"] == "system.github.rate_limited")) == 1
  end

  test "terminal workspace cleanup resolves the closed ticket's attentions", %{ledger: ledger} do
    # A non-binary workspace identifier fails the workspace entry fast; the
    # attentions are resolved before any entry runs.
    assert :ok = WorkspaceCleanup.start_terminal_workspace_cleanups([{"10", :not_a_leaf, nil}], ledger_path: ledger)
    assert_receive {:workspace_cleanup_finished, :not_a_leaf, {:error, _message}}, 10_000

    assert open_topics(ledger) == [
             "system.github.rate_limited",
             "ticket.10.agent.attention.error-state-write-failed",
             "ticket.10.agent.attention.merge_terminal_write_failed",
             "ticket.100.agent.attention.operator-decision"
           ]
  end

  defp open_topics(ledger) do
    [ledger_path: ledger, needs_attention: true]
    |> AlertFeed.list()
    |> Enum.map(& &1["topic"])
    |> Enum.sort()
  end
end
