defmodule Aiur.LandingWatch.ApprovedLandingFailureTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch

  test "failed CI on an approved auto-merging PR does not route rework" do
    observation = %{approved_observation() | auto_merge_request: %{"enabledAt" => "2026-10-16T07:54:08Z"}}
    assert :ok = process(observation)
    refute_received :rework
  end

  test "failed CI on an approved queued PR does not route rework" do
    observation = %{approved_observation() | merge_queue_entry: %{"id" => "MQE_1"}}
    assert :ok = process(observation)
    refute_received :rework
  end

  test "failed CI on an approved PR that is not landing still routes rework" do
    assert :ok = process(approved_observation())
    assert_received :rework
  end

  test "an observation without landing fields holds rework and raises attention" do
    observation = Map.drop(approved_observation(), [:auto_merge_request, :merge_queue_entry])
    assert :ok = process(observation)
    assert_received {:alert, "system.pr.landing.state_unavailable"}
    refute_received :rework
  end

  defp process(observation) do
    parent = self()

    LandingWatch.process(observation,
      approved_fun: fn _, _ -> {:ok, true} end,
      required_checks_fun: fn _ -> {:ok, [%{name: "ci gate", app_id: nil}]} end,
      ci_status_fun: fn _, _ -> {:ok, %{check_runs: [failed_gate()], commit_status: %{"state" => "success", "statuses" => []}}} end,
      jobs_fun: fn 99, _ -> {:ok, [%{"name" => "ci gate", "conclusion" => "failure", "steps" => [%{"conclusion" => "failure"}]}]} end,
      alert_emitter: fn topic, _details ->
        send(parent, {:alert, topic})
        :ok
      end,
      rework_fun: fn _, _, _ ->
        send(parent, :rework)
        :ok
      end
    )
  end

  defp approved_observation do
    %{
      number: 17,
      node_id: "PR_node",
      head: "head-sha",
      draft?: false,
      review_decision: "APPROVED",
      merge_queue_entry: nil,
      auto_merge_request: nil,
      rest: %{"head" => %{"ref" => "aiur/17-work"}},
      raw: %{"reviewDecision" => "APPROVED", "headRefOid" => "head-sha", "isDraft" => false, "reviews" => %{"nodes" => [%{"commit" => %{"oid" => "head-sha"}}]}}
    }
  end

  defp failed_gate do
    %{"id" => 50, "run_id" => 99, "name" => "ci gate", "status" => "completed", "conclusion" => "failure", "check_suite" => %{"id" => 100}}
  end
end
