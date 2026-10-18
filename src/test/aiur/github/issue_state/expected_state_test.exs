defmodule Aiur.GitHub.IssueState.ExpectedStateTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.IssueState
  alias Aiur.GitHub.ResourceStore

  @token_cache_key {Aiur.GitHub.Config, :resolved_token}

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    prev_cached_token = :persistent_term.get(@token_cache_key, :unset)
    :persistent_term.erase(@token_cache_key)
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", prev_token)

      case prev_cached_token do
        :unset -> :persistent_term.erase(@token_cache_key)
        token -> :persistent_term.put(@token_cache_key, token)
      end
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "sym"
    )

    ResourceStore.reset()
    on_exit(&ResourceStore.reset/0)
    :ok
  end

  describe "update_issue_state/3" do
    test "expected_state :none writes todo on a marker-only issue" do
      test_pid = self()
      body = %{"state" => "open", "labels" => [%{"name" => "sym:watch"}]}

      request_fun = fn request ->
        send(test_pid, {:request, request})
        {:ok, %{status: 200, body: body}}
      end

      assert :ok = IssueState.update_issue_state("42", "todo", expected_state: :none, request_fun: request_fun)
      assert_received {:request, %{method: :get}}
      assert_received {:request, %{method: :get}}
      assert_received {:request, %{method: :get}}
      assert_received {:request, %{method: :post, body: %{"labels" => ["sym:todo"]}}}
      refute_received {:request, %{method: :delete}}
    end

    test "expected_state :none refuses a state appearing before revalidation" do
      test_pid = self()
      gets = :ets.new(:gets, [:set, :private])

      request_fun = fn request ->
        send(test_pid, {:request, request})
        assert request.method == :get
        count = :ets.update_counter(gets, :count, 1, {:count, 0})
        labels = if count == 1, do: ["sym:watch"], else: ["sym:watch", "sym:in-progress"]
        {:ok, %{status: 200, body: %{"state" => "open", "labels" => Enum.map(labels, &%{"name" => &1})}}}
      end

      assert {:error, {:stale_issue_state, :none, "in-progress"}} =
               IssueState.update_issue_state("42", "todo", expected_state: :none, request_fun: request_fun)

      assert_received {:request, %{method: :get}}
      assert_received {:request, %{method: :get}}
      refute_received {:request, _}
    end

    test "rejects a stale expected state before mutating labels" do
      test_pid = self()

      request_fun = fn request ->
        send(test_pid, {:request, request})

        {:ok,
         %{
           status: 200,
           body: %{
             "state" => "open",
             "labels" => [%{"name" => "sym:rework"}]
           }
         }}
      end

      assert {:error, {:stale_issue_state, "ci-wait", "rework"}} =
               IssueState.update_issue_state("42", "in-progress",
                 expected_state: "ci-wait",
                 request_fun: request_fun
               )

      assert_receive {:request, %{method: :get}}, 1000
      refute_receive {:request, %{method: _method}}, 100
    end

    test "expected_state :none refuses existing single or multiple state labels" do
      for states <- [["in-progress"], ["todo", "in-progress"]] do
        request_fun = fn request ->
          assert request.method == :get
          {:ok, %{status: 200, body: %{"state" => "open", "labels" => Enum.map(states, &%{"name" => "sym:#{&1}"})}}}
        end

        assert {:error, {:stale_issue_state, :none, actual}} =
                 IssueState.update_issue_state("42", "todo", expected_state: :none, request_fun: request_fun)

        assert actual in states
        ResourceStore.reset()
      end
    end

    test "regression guard: expected_state :none refuses a closed issue" do
      body = %{"state" => "closed", "labels" => [%{"name" => "sym:watch"}]}

      request_fun = fn request ->
        assert request.method == :get
        {:ok, %{status: 200, body: body}}
      end

      assert {:error, {:no_state_label_written, ^body}} =
               IssueState.update_issue_state("42", "todo", expected_state: :none, request_fun: request_fun)

      refute_received {:request, %{method: :post}}
      refute_received {:request, %{method: :delete}}
    end

    test "revalidates expected state after the human-review gate" do
      test_pid = self()
      issue_gets = :ets.new(:issue_gets, [:set, :public])
      :ets.insert(issue_gets, {:count, 0})

      request_fun = fn request ->
        send(test_pid, {:request, request})

        cond do
          request.method == :get and String.contains?(request.url, "/issues/42") ->
            [{:count, count}] = :ets.lookup(issue_gets, :count)
            :ets.insert(issue_gets, {:count, count + 1})

            if count == 0 do
              {:ok, %{status: 200, headers: [{"etag", "stale-validator"}], body: %{"state" => "open", "labels" => [%{"name" => "sym:ci-wait"}]}}}
            else
              refute Map.has_key?(request, :etag)
              {:ok, %{status: 200, body: %{"state" => "open", "labels" => [%{"name" => "sym:rework"}]}}}
            end

          request.method == :get and String.contains?(request.url, "/pulls?") ->
            {:ok, %{status: 200, body: [], headers: []}}

          true ->
            flunk("unexpected request: #{inspect(request)}")
        end
      end

      assert {:error, {:stale_issue_state, "ci-wait", "rework"}} =
               IssueState.update_issue_state("42", "human-review",
                 expected_state: "ci-wait",
                 request_fun: request_fun
               )

      assert_receive {:request, %{method: :get, url: issue_url}}, 1000
      assert issue_url =~ "/issues/42"
      refute_receive {:request, %{method: :get, url: ^issue_url, etag: _etag}}, 100
      # One open-pull-request listing, not two: the `head=<owner>:aiur/42` probe
      # that used to run in front of it matched only branches the listing's own
      # filter already accepts, so it was a billed request that answered nothing
      # the next one did not.
      assert_receive {:request, %{method: :get, url: ticket_pull_url}}, 1000
      assert ticket_pull_url =~ "/pulls?"
      refute ticket_pull_url =~ "head="
      assert_receive {:request, %{method: :get, url: ^issue_url}}, 1000
      refute_receive {:request, %{method: _method}}, 100
    end
  end
end
