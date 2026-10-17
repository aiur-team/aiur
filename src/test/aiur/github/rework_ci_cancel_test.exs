defmodule Aiur.GitHub.ReworkCICancelTest do
  use ExUnit.Case, async: false

  alias Aiur.GitHub.ReworkCICancel
  alias Aiur.Issue
  alias Aiur.Orchestrator.{IssueSync, State}

  def record_cancel(issue_id), do: send(:rework_ci_cancel_test, {:cancel, issue_id})

  defp run(id, name, status, sha \\ "head"), do: %{"id" => id, "name" => name, "status" => status, "head_sha" => sha}

  test "cancels only the PR head's active ci and pr body runs" do
    test = self()

    request = fn %{method: :get, url: url} ->
      send(test, {:listed, url})

      {:ok,
       %{
         status: 200,
         body: %{
           "workflow_runs" => [
             run(1, "ci", "in_progress"),
             run(2, "pr body", "queued"),
             run(3, "ci", "completed"),
             run(4, "website", "queued"),
             run(5, "ci", "queued", "older-head"),
             run(6, "ci", "waiting")
           ]
         }
       }}
    end

    cancel = fn id, _opts ->
      send(test, {:cancelled, id})
      if id == 6, do: {:error, :conflict}, else: :ok
    end

    assert {:ok, [1, 2]} =
             ReworkCICancel.cancel("17",
               token: "test-gh-token",
               request_fun: request,
               cancel_fun: cancel,
               open_pr_fun: fn "17" -> {:ok, %{"number" => 42, "head" => %{"sha" => "head"}}} end
             )

    assert_received {:listed, url}
    assert url =~ "/actions/runs?head_sha=head&event=pull_request&per_page=100"
    assert_received {:cancelled, 1}
    assert_received {:cancelled, 2}
    assert_received {:cancelled, 6}
    refute_received {:cancelled, _}
  end

  test "a ticket without an open PR cancels nothing and errors pass through" do
    assert {:ok, []} = ReworkCICancel.cancel("17", open_pr_fun: fn _ -> {:ok, nil} end, cancel_fun: fn _, _ -> flunk("cancelled") end)
    assert {:error, :boom} = ReworkCICancel.cancel("17", open_pr_fun: fn _ -> {:error, :boom} end)
  end

  test "a polled entry into rework fires the canceller once, whoever wrote the label" do
    Process.register(self(), :rework_ci_cancel_test)
    prior = [{:github_rework_ci_canceller, Application.fetch_env(:aiur, :github_rework_ci_canceller)}]
    on_exit(fn -> Aiur.TestSupport.restore_app_env(prior) end)
    Application.put_env(:aiur, :github_rework_ci_canceller, {__MODULE__, :record_cancel})

    state = sync(%State{}, [%Issue{id: "11", identifier: "11", state: "human-review"}, %Issue{id: "12", identifier: "12", state: "in-progress"}])
    refute_received {:cancel, _}

    # An Executor `gh issue edit` reaches the daemon only through the poll diff.
    state = sync(state, [%Issue{id: "11", identifier: "11", state: "rework"}, %Issue{id: "12", identifier: "12", state: "ci-wait"}])
    assert_received {:cancel, "11"}
    refute_received {:cancel, _}

    _state = sync(state, [%Issue{id: "11", identifier: "11", state: "rework"}])
    refute_received {:cancel, _}
  end

  test "the runs listing and cancels carry their own cost caller" do
    test = self()

    request = fn req ->
      send(test, {:caller, req.method, req.caller})
      if req.method == :get, do: {:ok, %{status: 200, body: %{"workflow_runs" => [run(1, "ci", "queued")]}}}, else: {:ok, %{status: 202, body: %{}}}
    end

    assert {:ok, [1]} = ReworkCICancel.cancel("17", token: "test-gh-token", request_fun: request, open_pr_fun: fn _ -> {:ok, %{"head" => %{"sha" => "head"}}} end)
    assert_received {:caller, :get, "rework_ci_cancel"}
    assert_received {:caller, :post, "rework_ci_cancel"}
  end

  defp sync(state, issues),
    do: IssueSync.sync_polled_issue_state(state, issues, fn _ -> {:ok, []} end, fn _, _ -> :ok end, MapSet.new(["done"]), fn _ -> :ok end, fn _, _ -> :ok end)
end
