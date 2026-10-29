defmodule Aiur.Orchestrator.StartupClaimReconcilerReleaseWakesTest do
  use ExUnit.Case, async: false

  alias Aiur.Issue
  alias Aiur.Orchestrator.{StartupClaimReconciler, State}

  test "a rework claim waiting at fleet capacity is not observed or released across polls" do
    issue = issue("5330", "rework")

    state = %State{
      max_concurrent_agents: 1,
      effective_concurrent_agents: 1,
      running: %{"active" => %{issue: issue("active", "in-progress"), identifier: "active", control: %{status: :working}}}
    }

    state =
      Enum.reduce(1..4, state, fn _, current ->
        {next, [^issue]} =
          reconcile(current, issue, update_issue_state_fun: fn _, _, _ -> flunk("a rework ticket waiting for capacity is not an orphan") end)

        assert next.orphaned_claim_since == %{}
        next
      end)

    assert state.startup_claim_reconciliation_complete?
    refute_receive {:alert, "ticket.5330.agent.attention.startup_orphan_claim_released", _opts}, 100
  end

  test "a successful release that leaves labels unchanged does not wake the Executor" do
    issue = issue("same-state", "in-progress")

    {state, [%Issue{state: "in-progress"}]} =
      reconcile(%State{}, issue,
        forced_target: "in-progress",
        update_issue_state_fun: fn "same-state", "in-progress", "in-progress" -> :ok end,
        emit_alert_fun: fn topic, _opts -> flunk("an unchanged state must not publish #{topic}") end
      )

    assert state.startup_claim_reconciliation_complete?
  end

  defp reconcile(state, issue, opts) do
    defaults = [grace_ms: 0, open_pr_fetcher: fn _ -> {:ok, nil} end, create_comment_fun: fn _, _ -> :ok end, emit_alert_fun: fn _, _ -> :ok end]
    StartupClaimReconciler.reconcile(state, [issue], Keyword.merge(defaults, opts))
  end

  defp issue(identifier, state) do
    %Issue{id: "issue-#{identifier}", identifier: identifier, title: "Ticket #{identifier}", state: state}
  end
end
