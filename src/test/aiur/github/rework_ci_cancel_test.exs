defmodule Aiur.GitHub.ReworkCICancelTest do
  use ExUnit.Case, async: false

  alias Aiur.GitHub.{ReworkCICancel, Tracker}

  defmodule Client do
    def update_issue_state(_id, "fail"), do: {:error, :boom}
    def update_issue_state(_id, _state), do: :ok
  end

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

  test "a successful rework write fires the canceller; other writes do not" do
    Process.register(self(), :rework_ci_cancel_test)
    prior = Enum.map([:github_client_module, :github_rework_ci_canceller], &{&1, Application.fetch_env(:aiur, &1)})
    on_exit(fn -> Aiur.TestSupport.restore_app_env(prior) end)
    Application.put_env(:aiur, :github_client_module, Client)
    Application.put_env(:aiur, :github_rework_ci_canceller, {__MODULE__, :record_cancel})

    assert :ok = Tracker.update_issue_state("11", "rework")
    assert :ok = Tracker.update_issue_state("12", "Rework", [])
    assert :ok = Tracker.update_issue_state("13", "human-review")
    assert {:error, :boom} = Tracker.update_issue_state("14", "fail")

    assert_received {:cancel, "11"}
    assert_received {:cancel, "12"}
    refute_received {:cancel, _}
  end
end
