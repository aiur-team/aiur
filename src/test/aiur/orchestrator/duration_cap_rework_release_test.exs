defmodule Aiur.Orchestrator.DurationCapReworkReleaseTest do
  use ExUnit.Case, async: false

  alias Aiur.Issue
  alias Aiur.Orchestrator.{DurationCapRelease, State}

  setup do
    previous = Application.get_env(:aiur, :duration_cap_retry_store_path)
    path = Path.join(Aiur.TestSupport.tmp_root!("duration-cap-rework-release"), "retries.json")
    Application.put_env(:aiur, :duration_cap_retry_store_path, path)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:aiur, :duration_cap_retry_store_path, previous),
        else: Application.delete_env(:aiur, :duration_cap_retry_store_path)

      Aiur.TestCleanup.rm_rf!(Path.dirname(path))
    end)
  end

  test "an unchanged head with a blocking review stays in rework and redispatches" do
    entry = parked_entry()
    state = %State{running: %{entry.issue.id => entry}}

    dispatch = fn current, issue, _attempt, _host, dispatch_opts ->
      send(self(), {:redispatch, issue.identifier, issue.state})

      started = %{
        current
        | running: Map.put(current.running, issue.id, %{control: %{status: :working}})
      }

      dispatch_opts[:dispatch_result_fun].(started)
    end

    released =
      DurationCapRelease.maybe_release(
        state,
        entry,
        :paused,
        release_opts("reviewed-head", dispatch)
      )

    assert released.running[entry.issue.id].control.status == :working
    assert_received {:redispatch, "4849", "rework"}
  end

  test "a changed head since a blocking review hands back for human review" do
    entry = parked_entry()
    state = %State{running: %{entry.issue.id => entry}}

    opts =
      release_opts("new-head", fn current, _issue, _attempt, _host, dispatch_opts ->
        dispatch_opts[:dispatch_result_fun].(current)
      end)
      |> Keyword.merge(
        update_issue_state_fun: fn identifier, target, expected ->
          send(self(), {:write, identifier, target, expected})
          :ok
        end,
        create_comment_fun: fn _, _ -> :ok end
      )

    released = DurationCapRelease.maybe_release(state, entry, :paused, opts)

    assert_received {:write, "4849", "human-review", "in-progress"}
    refute Map.has_key?(released.running, entry.issue.id)
  end

  defp release_opts(head, dispatch) do
    [
      workspace_probe: fn _, _ -> {:ok, "after"} end,
      open_pr_fetcher: fn _ -> {:ok, %{"number" => 42}} end,
      pr_fetcher: fn 42 ->
        {:ok, %{"number" => 42, "draft" => false, "mergeable" => true, "head" => %{"sha" => head}}}
      end,
      reviews_fetcher: fn 42 ->
        {:ok,
         [
           %{
             "state" => "CHANGES_REQUESTED",
             "commit_id" => "reviewed-head",
             "submitted_at" => "2026-10-20T00:00:00Z",
             "user" => %{"login" => "reviewer"},
             authoritative: true
           }
         ]}
      end,
      unresolved_threads_fetcher: fn _ -> {:ok, []} end,
      dispatch_fun: dispatch,
      duration_cap_retry_count_fun: fn _ -> 0 end,
      increment_duration_cap_retry_fun: fn _ -> :ok end,
      max_retry_attempts: 3,
      emit_alert_fun: fn _, _ -> :ok end
    ]
  end

  defp parked_entry do
    %{
      pid: nil,
      ref: nil,
      identifier: "4849",
      issue: %Issue{id: "issue-4849", identifier: "4849", state: "in-progress"},
      started_at: DateTime.add(DateTime.utc_now(), -7200, :second),
      paused_reason: :max_agent_duration,
      control: %{status: :paused},
      retry_attempt: 0,
      workspace_path: "/workspace",
      duration_cap_progress_baseline: "before",
      worker_host: nil,
      session_id: "session-1"
    }
  end
end
