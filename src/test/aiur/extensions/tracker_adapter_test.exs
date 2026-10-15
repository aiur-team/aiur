defmodule Aiur.Extensions.TrackerAdapterTest do
  use Aiur.TestSupport
  alias Aiur.Linear.Tracker, as: LinearTracker
  alias Aiur.Memory.Tracker, as: Memory

  defmodule FakeLinearClient do
    def fetch_candidate_issues do
      send(self(), :fetch_candidate_issues_called)
      {:ok, [:candidate]}
    end

    def fetch_issues_by_states(states), do: fetch_issues_by_states(states, [])

    def fetch_issues_by_states(states, _opts) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:fetch_issue_states_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end

    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})

      case Process.get({__MODULE__, :graphql_results}) do
        [result | rest] ->
          Process.put({__MODULE__, :graphql_results}, rest)
          result

        _ ->
          Process.get({__MODULE__, :graphql_result})
      end
    end
  end

  setup do
    linear_client_module = Application.get_env(:aiur, :linear_client_module)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:aiur, :linear_client_module)
      else
        Application.put_env(:aiur, :linear_client_module, linear_client_module)
      end
    end)

    :ok
  end

  setup do
    endpoint_config = Application.get_env(:aiur, AiurWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:aiur, AiurWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "tracker delegates to memory and linear adapters" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "In Progress"}
    Application.put_env(:aiur, :memory_tracker_issues, [issue, %{id: "ignored"}])
    Application.put_env(:aiur, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert Config.settings!().tracker.kind == "memory"
    assert Aiur.Tracker.adapter() == Memory
    assert Memory.project_identity() == "memory"
    assert Memory.default_prompt_template() =~ "You are working on an issue."
    assert {:ok, [^issue]} = Aiur.Tracker.fetch_candidate_issues()
    assert {:ok, [^issue]} = Aiur.Tracker.fetch_issues_by_states([" in progress ", 42])
    assert {:ok, [^issue]} = Aiur.Tracker.fetch_issue_states_by_ids(["issue-1"])
    assert :ok = Aiur.Tracker.create_comment("issue-1", "comment")
    assert :ok = Aiur.Tracker.update_issue_state("issue-1", "Done")
    assert_receive {:memory_tracker_comment, "issue-1", "comment"}, 1000
    assert_receive {:memory_tracker_state_update, "issue-1", "Done"}, 1000

    assert :ok =
             Aiur.Tracker.update_issue_state("issue-1", "Todo", expected_state: "in-progress")

    assert_receive {:memory_tracker_state_update, "issue-1", "Todo"}, 1000
    assert [%Issue{state: "Todo"}, %{id: "ignored"}] = Application.fetch_env!(:aiur, :memory_tracker_issues)

    assert {:error, {:stale_issue_state, "in-progress", "todo"}} =
             Aiur.Tracker.update_issue_state("issue-1", "Done", expected_state: "In Progress")

    refute_receive {:memory_tracker_state_update, "issue-1", "Done"}, 100

    Application.delete_env(:aiur, :memory_tracker_recipient)
    assert :ok = Memory.create_comment("issue-1", "quiet")
    assert :ok = Memory.update_issue_state("issue-1", "Quiet")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    assert Aiur.Tracker.adapter() == LinearTracker
  end

  test "linear adapter delegates reads and validates mutation responses" do
    Application.put_env(:aiur, :linear_client_module, FakeLinearClient)

    assert {:ok, [:candidate]} = LinearTracker.fetch_candidate_issues()
    assert_receive :fetch_candidate_issues_called, 1000

    assert {:ok, ["Todo"]} = LinearTracker.fetch_issues_by_states(["Todo"])
    assert_receive {:fetch_issues_by_states_called, ["Todo"]}, 1000

    assert {:ok, ["issue-1"]} = LinearTracker.fetch_issue_states_by_ids(["issue-1"])
    assert_receive {:fetch_issue_states_by_ids_called, ["issue-1"]}, 1000

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
    )

    assert :ok = LinearTracker.create_comment("issue-1", "hello")
    assert_receive {:graphql_called, create_comment_query, %{body: "hello", issueId: "issue-1"}}, 1000
    assert create_comment_query =~ "commentCreate"

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}}
    )

    assert {:error, :comment_create_failed} =
             LinearTracker.create_comment("issue-1", "broken")

    Process.put({FakeLinearClient, :graphql_result}, {:error, :boom})

    assert {:error, :boom} = LinearTracker.create_comment("issue-1", "boom")

    Process.put({FakeLinearClient, :graphql_result}, {:ok, %{"data" => %{}}})
    assert {:error, :comment_create_failed} = LinearTracker.create_comment("issue-1", "weird")

    Process.put({FakeLinearClient, :graphql_result}, :unexpected)
    assert {:error, :comment_create_failed} = LinearTracker.create_comment("issue-1", "odd")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      ]
    )

    assert :ok = LinearTracker.update_issue_state("issue-1", "Done")
    assert_receive {:graphql_called, state_lookup_query, %{issueId: "issue-1", stateName: "Done"}}, 1000
    assert state_lookup_query =~ "states"

    assert_receive {:graphql_called, update_issue_query, %{issueId: "issue-1", stateId: "state-1"}}, 1000

    assert update_issue_query =~ "issueUpdate"

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => false}}}}
      ]
    )

    assert {:error, :issue_update_failed} =
             LinearTracker.update_issue_state("issue-1", "Broken")

    Process.put({FakeLinearClient, :graphql_results}, [{:error, :boom}])

    assert {:error, :boom} = LinearTracker.update_issue_state("issue-1", "Boom")

    Process.put({FakeLinearClient, :graphql_results}, [{:ok, %{"data" => %{}}}])
    assert {:error, :state_not_found} = LinearTracker.update_issue_state("issue-1", "Missing")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{}}}
      ]
    )

    assert {:error, :issue_update_failed} = LinearTracker.update_issue_state("issue-1", "Weird")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        :unexpected
      ]
    )

    assert {:error, :issue_update_failed} = LinearTracker.update_issue_state("issue-1", "Odd")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{
               "state" => %{"name" => "In Progress"},
               "team" => %{"states" => %{"nodes" => [%{"id" => "state-todo"}]}}
             }
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      ]
    )

    assert :ok =
             LinearTracker.update_issue_state("issue-1", "Todo", expected_state: "in-progress")

    assert_receive {:graphql_called, guarded_lookup_query, %{issueId: "issue-1", stateName: "Todo"}}, 1000

    assert guarded_lookup_query =~ "state"
    assert_receive {:graphql_called, _guarded_update_query, %{issueId: "issue-1", stateId: "state-todo"}}, 1000

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{
               "state" => %{"name" => "Todo"},
               "team" => %{"states" => %{"nodes" => [%{"id" => "state-done"}]}}
             }
           }
         }}
      ]
    )

    assert {:error, {:stale_issue_state, "in-progress", "todo"}} =
             LinearTracker.update_issue_state("issue-1", "Done", expected_state: "In Progress")

    assert_receive {:graphql_called, _stale_lookup_query, %{issueId: "issue-1", stateName: "Done"}}, 1000
    refute_receive {:graphql_called, _query, %{stateId: "state-done"}}, 100
  end
end
