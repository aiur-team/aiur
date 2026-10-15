defmodule Aiur.GitHub.ComponentBoundaryTest do
  use ExUnit.Case, async: false

  alias Aiur.BuildOrder.Component
  alias Aiur.GitHub.{Quota, Tracker, Transport, ViewStateSweep}

  defmodule Client do
    def update_issue_state(_id, _state), do: :ok
  end

  def record_activity(repo, opts), do: send(__MODULE__, {:activity, repo, opts})
  def record_start(id, source, at), do: send(self(), {:start, id, source, at})

  setup do
    keys = [:github_poll_owner, :github_quota_recovery_target, :github_activity_recorder, :github_state_start_recorder, :github_client_module, :view_state_sources]
    prior = Enum.map(keys, &{&1, Application.fetch_env(:aiur, &1)})

    on_exit(fn -> Aiur.TestSupport.restore_app_env(prior) end)

    :ok
  end

  test "composition config keeps the existing owners and sweep source" do
    assert Application.get_env(:aiur, :github_poll_owner) == Aiur.Orchestrator
    assert Application.get_env(:aiur, :github_quota_recovery_target) == Aiur.Orchestrator
    assert Application.get_env(:aiur, :github_activity_recorder) == {Aiur.Webhooks, :record_activity}
    assert Application.get_env(:aiur, :github_state_start_recorder) == {Aiur.BuildOrder.History, :note_start}
    assert Application.get_env(:aiur, :view_state_sources) == [Aiur.BuildOrder.PackStatus]
    assert Component.child_specs(:view_state_sweep, []) == [{ViewStateSweep, sources: [Aiur.BuildOrder.PackStatus]}]
  end

  test "composition passes the configured sweep sources" do
    Application.put_env(:aiur, :view_state_sources, [])
    assert Component.child_specs(:view_state_sweep, []) == [{ViewStateSweep, sources: []}]
  end

  test "quota recovery notifies the configured target" do
    Process.register(self(), __MODULE__)
    Application.put_env(:aiur, :github_quota_recovery_target, __MODULE__)
    quota = start_supervised!({Quota, name: nil, refresh?: false, hold_dir: nil, request_log_path: nil, shell_log_path: nil, stale_broker_path: nil})
    request = %{method: :get, url: "https://api.github.com/repos/owner/repo/issues"}
    reset = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_unix() |> to_string()

    response = fn remaining ->
      {:ok, %{status: 200, headers: [{"x-ratelimit-resource", "core"}, {"x-ratelimit-limit", "5000"}, {"x-ratelimit-remaining", to_string(remaining)}, {"x-ratelimit-reset", reset}], body: %{}}}
    end

    Quota.observe(quota, request, response.(500))
    assert {:hold, %{resource: "core"}} = Quota.dispatch_status(quota)
    Quota.observe(quota, request, response.(4500))
    assert :available = Quota.dispatch_status(quota)
    assert_received :github_quota_recovered
  end

  test "only the configured poll owner gets the tighter request deadline" do
    Process.register(self(), __MODULE__)
    Application.put_env(:aiur, :github_poll_owner, __MODULE__)
    assert Transport.request_deadline_ms(%{}) == 10_000
    Application.delete_env(:aiur, :github_poll_owner)
    assert Transport.request_deadline_ms(%{}) == 60_000
  end

  test "sweep sends the observed head through the configured activity recorder" do
    Process.register(self(), __MODULE__)
    Application.put_env(:aiur, :github_activity_recorder, {__MODULE__, :record_activity})

    sweep =
      start_supervised!(
        {ViewStateSweep,
         name: nil,
         sources: [],
         interval_ms: 3_600_000,
         repo_fun: fn -> {:ok, {"owner", "repo"}} end,
         token_fun: fn -> {:ok, "test-token"} end,
         request_fun: fn _ -> {:ok, %{status: 200, headers: [], body: [%{"updated_at" => "2026-10-14T10:00:00Z"}]}} end}
      )

    assert ViewStateSweep.sweep_now(sweep) == []
    assert_received {:activity, "owner/repo", [observation: {:issue_head, "2026-10-14T10:00:00Z"}]}
  end

  test "successful in-progress writes call the configured start recorder" do
    Application.put_env(:aiur, :github_client_module, Client)
    Application.put_env(:aiur, :github_state_start_recorder, {__MODULE__, :record_start})
    assert Tracker.update_issue_state("3301", "in-progress") == :ok
    assert_received {:start, "3301", :label, %DateTime{}}
    Application.delete_env(:aiur, :github_state_start_recorder)
    assert Tracker.update_issue_state("3301", "in-progress") == :ok
    refute_received {:start, _, _, _}
  end
end
