defmodule Aiur.Orchestrator.MergedRoundHandoffTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner.ToolExecutor
  alias Aiur.Issue

  # open-games #644: round PR #666 merged while the creator's verdict was still
  # open, and the handoff refused `:no_open_pr`, so the worker had to raise an
  # Executor Command just to be relabeled.
  @merge %{ticket_id: "644", number: 666}

  test "a rework ticket whose PR merged hands off to human-review while a creator Command is open" do
    assert {:wrote, "human-review"} = hand_off([@merge], [command(audience: :creator)])
  end

  test "a human-required Command routed by authority counts as a creator Command" do
    assert {:wrote, "human-review"} = hand_off([@merge], [command(audience: nil, authority: :human_required)])
  end

  test "without an open creator Command the merged ticket is still refused" do
    assert {:refused, message} = hand_off([@merge], [command(audience: :creator, decision_status: :answered)])
    assert message =~ ":no_open_pr"
  end

  test "an Executor-audience Command does not unlock the handoff" do
    assert {:refused, _message} = hand_off([@merge], [command(audience: :executor, authority: :human_required)])
  end

  test "a creator Command on another ticket does not unlock the handoff" do
    assert {:refused, _message} = hand_off([@merge], [command(audience: :creator, ticket: %{identifier: "645"})])
  end

  test "without a merged PR for the ticket the handoff is still refused" do
    assert {:refused, _message} = hand_off([%{ticket_id: "645", number: 667}], [command(audience: :creator)])
  end

  test "ci-wait still needs an open PR" do
    assert {:refused, _message} = hand_off([@merge], [command(audience: :creator)], "ci-wait")
  end

  defp command(fields) do
    Map.merge(%{decision_id: "dec_6fc549f3e798d82f", ticket: %{identifier: "644"}, decision_status: :open, authority: :supervisor_allowed, legacy_attention: nil}, Map.new(fields))
  end

  defp hand_off(merges, decisions, state \\ "human-review") do
    issue = %Issue{id: "gid-644", identifier: "644", state: "rework"}
    test_pid = self()

    executor =
      ToolExecutor.build(issue, nil, nil, %{},
        coordination_runner: fn _key, operation, _opts -> operation.() end,
        ticket_state_writer: fn _issue_id, target ->
          send(test_pid, {:wrote, target})
          :ok
        end,
        open_pr_fetcher: fn _ -> {:ok, nil} end,
        recent_merges_fun: fn -> merges end,
        decisions_fun: fn -> decisions end
      )

    response = executor.("aiur_set_ticket_state", %{"state" => state})

    receive do
      {:wrote, target} -> {:wrote, target}
    after
      0 ->
        refute response["success"]
        {:refused, Jason.decode!(response["output"])["error"]["message"]}
    end
  end
end
