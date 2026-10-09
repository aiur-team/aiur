defmodule Aiur.GitHub.IssueClosureTest do
  use Aiur.TestSupport
  alias Aiur.GitHub.{Issues, Tracker}

  defmodule Client do
    def fetch_issue_raw_conditional(id, opts) do
      send(self(), {:closure_read, id, opts})
      Process.get(:closure_response)
    end
  end

  setup do
    previous = Application.get_env(:aiur, :github_client_module)
    Application.put_env(:aiur, :github_client_module, Client)
    on_exit(fn -> if previous, do: Application.put_env(:aiur, :github_client_module, previous), else: Application.delete_env(:aiur, :github_client_module) end)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    :ok
  end

  test "conditional request carries caller option and default" do
    for caller <- [nil, "build_queue_observe"] do
      opts = [
        repository: {"closure", "test"},
        token: "test-token",
        request_fun: fn request ->
          assert request.caller == (caller || "issue_raw_conditional")
          {:ok, %{status: 200, body: %{"state" => "closed", "state_reason" => "completed"}}}
        end
      ]

      opts = if caller, do: Keyword.put(opts, :caller, caller), else: opts
      assert {:ok, %{"state_reason" => "completed"}, :fetched} = Issues.fetch_issue_raw_conditional("77", opts)
    end
  end

  test "tracker maps state with attributed freshness-bounded read" do
    Process.put(:closure_response, {:ok, %{"state" => "closed", "state_reason" => "not_planned"}, :fresh})
    assert Tracker.issue_closure("77") == {:ok, %{open?: false, state_reason: "not_planned"}}
    assert_received {:closure_read, "77", opts}
    assert opts[:caller] == "build_queue_observe"
    assert opts[:freshness_ms] == Aiur.BuildQueue.Settings.observation_max_age_ms(Aiur.Config.settings!())
    Process.put(:closure_response, {:ok, %{"state" => "open", "state_reason" => nil}, :fetched})
    assert Tracker.issue_closure("77") == {:ok, %{open?: true, state_reason: nil}}
    Process.put(:closure_response, {:error, :timeout})
    assert Tracker.issue_closure("77") == {:error, :timeout}
    Process.put(:closure_response, {:ok, %{}, :fetched})
    assert Tracker.issue_closure("77") == {:error, :invalid_issue_closure}
  end

  test "unsupported adapters fail closed" do
    assert Aiur.Memory.Tracker.issue_closure("77") == {:error, :unsupported}
    assert Aiur.Linear.Tracker.issue_closure("77") == {:error, :unsupported}
  end
end
