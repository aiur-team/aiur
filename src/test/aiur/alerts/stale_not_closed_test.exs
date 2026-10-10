defmodule Aiur.Alerts.StaleNotClosedTest do
  use ExUnit.Case, async: true

  alias Aiur.{AlertFeed, AlertLedger}
  alias Aiur.Alerts.StaleNotClosed
  alias Aiur.GitHub.Issues, as: GitHubIssues

  setup do
    root = Aiur.TestSupport.tmp_root!("aiur-stale-not-closed")
    ledger = Path.join(root, "project.alerts.ndjson")
    on_exit(fn -> File.rm_rf!(root) end)

    for id <- ["10", "11"] do
      :ok =
        AlertLedger.append(
          %{
            "event" => "alert",
            "timestamp" => "2026-10-01T00:00:00Z",
            "topic" => "ticket.#{id}.agent.attention.merge_terminal_write_failed",
            "message" => "ticket was not closed",
            "needs_attention" => true,
            "source_ticket_id" => id
          },
          ledger_path: ledger
        )
    end

    :ok =
      AlertLedger.append(
        %{
          "event" => "alert",
          "timestamp" => "2026-10-01T00:00:00Z",
          "topic" => "ticket.10.merge.attribution_check_failed",
          "message" => "attribution could not be determined",
          "needs_attention" => true,
          "source_ticket_id" => "10"
        },
        ledger_path: ledger
      )

    alert_fun = fn topic, message, opts ->
      AlertLedger.append(
        %{
          "event" => "alert",
          "timestamp" => "2026-10-02T00:00:00Z",
          "topic" => topic,
          "message" => message,
          "needs_attention" => opts[:needs_attention],
          "source_ticket_id" => opts[:issue]
        },
        ledger_path: ledger
      )
    end

    {:ok, opts: [ledger_paths: [ledger], alert_fun: alert_fun]}
  end

  test "reconcile resolves the alert of a done ticket and keeps an open ticket's", %{opts: opts} do
    assert :ok = StaleNotClosed.reconcile(fn ["10", "11"] -> ["10"] end, opts)

    assert [%{"topic" => "ticket.11.agent.attention.merge_terminal_write_failed"}] =
             AlertFeed.list([needs_attention: true] ++ opts)
  end

  test "reconcile also resolves attribution alerts of a done ticket", %{opts: opts} do
    :ok = StaleNotClosed.reconcile(fn ids -> ids -- ["11"] end, opts)

    assert [%{"topic" => "ticket.11.agent.attention.merge_terminal_write_failed"}] =
             AlertFeed.list([needs_attention: true] ++ opts)
  end

  test "resolve is a no-op once nothing is open", %{opts: opts} do
    :ok = StaleNotClosed.resolve("10", opts)
    :ok = StaleNotClosed.resolve("10", opts)

    assert [%{"topic" => "ticket.11" <> _}] = AlertFeed.list([needs_attention: true] ++ opts)
  end

  test "done_ids resolves closed agent:done issues and keeps open ones" do
    issue = fn number, state, label ->
      GitHubIssues.normalize_issue(
        %{"number" => number, "state" => state, "labels" => [%{"name" => label}]},
        "o",
        "r",
        "agent"
      )
    end

    issues = [
      issue.(1, "closed", "agent:done"),
      issue.(2, "open", "agent:done"),
      issue.(3, "closed", "agent:todo")
    ]

    assert ["1"] = StaleNotClosed.done_ids(["1", "2", "3"], fetch_fun: fn _ -> {:ok, issues} end)
    assert [] = StaleNotClosed.done_ids(["1"], fetch_fun: fn _ -> {:error, :boom} end)
  end
end
