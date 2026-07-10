defmodule Aiur.GitHub.IssueStateTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.IssueState

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

    :ok
  end

  describe "update_issue_state/3" do
    test "removes all sym:* labels and adds the single new state label" do
      calls = :ets.new(:calls, [:set, :public])
      :ets.insert(calls, {:count, 0})

      request_fun = fn req ->
        [{:count, n}] = :ets.lookup(calls, :count)
        :ets.insert(calls, {:count, n + 1})

        case {req.method, n} do
          {:get, 0} ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "state" => "open",
                 "labels" => [%{"name" => "sym:todo"}, %{"name" => "other"}]
               }
             }}

          {:delete, 1} ->
            assert req.url =~ "sym%3Atodo" or req.url =~ "sym:todo"
            {:ok, %{status: 200}}

          {:get, 2} ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "state" => "open",
                 "labels" => [%{"name" => "other"}]
               }
             }}

          {:post, 3} ->
            assert req.body == %{"labels" => ["sym:rework"]}
            {:ok, %{status: 200}}

          _ ->
            {:ok, %{status: 200}}
        end
      end

      assert :ok = IssueState.update_issue_state("42", "rework", request_fun: request_fun)
    end

    test "terminal target state closes the issue" do
      calls = :ets.new(:calls, [:set, :public])
      :ets.insert(calls, {:count, 0})

      request_fun = fn req ->
        [{:count, n}] = :ets.lookup(calls, :count)
        :ets.insert(calls, {:count, n + 1})

        case {req.method, n} do
          {:get, 0} ->
            {:ok,
             %{
               status: 200,
               body: %{"state" => "open", "labels" => [%{"name" => "sym:in-progress"}]}
             }}

          {:delete, 1} ->
            {:ok, %{status: 200}}

          {:post, 2} ->
            assert req.body == %{"labels" => ["sym:done"]}
            {:ok, %{status: 200}}

          {:patch, 3} ->
            assert req.body == %{"state" => "closed"}
            {:ok, %{status: 200}}

          _ ->
            {:ok, %{status: 200}}
        end
      end

      assert :ok = IssueState.update_issue_state("42", "Done", request_fun: request_fun)
    end

    test "closed-issue active-target branch strips active labels without adding the new one" do
      test_pid = self()

      request_fun = fn req ->
        send(test_pid, {:request, req})

        case req.method do
          :get ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "state" => "closed",
                 "labels" => [
                   %{"name" => "sym:done"},
                   %{"name" => "sym:human-review"},
                   %{"name" => "sym:rework"}
                 ]
               }
             }}

          _ ->
            {:ok, %{status: 200}}
        end
      end

      assert :ok = IssueState.update_issue_state("42", "rework", request_fun: request_fun)

      # Only deletes non-terminal active labels; does not POST a new label or PATCH close
      assert_receive {:request, %{method: :get}}
      assert_receive {:request, %{method: :delete}}
      refute_receive {:request, %{method: :post}}, 100
      refute_receive {:request, %{method: :patch}}, 100
    end

    test "add_active_issue_label re-checks issue closed state before adding (stale-label race)" do
      test_pid = self()
      calls = :ets.new(:calls, [:set, :public])
      :ets.insert(calls, {:count, 0})

      request_fun = fn req ->
        send(test_pid, {:request, req})
        [{:count, n}] = :ets.lookup(calls, :count)
        :ets.insert(calls, {:count, n + 1})

        case {req.method, n} do
          {:get, 0} ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "state" => "open",
                 "labels" => [%{"name" => "sym:human-review"}]
               }
             }}

          {:delete, 1} ->
            {:ok, %{status: 200}}

          {:get, 2} ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "state" => "closed",
                 "labels" => [%{"name" => "sym:done"}, %{"name" => "sym:rework"}]
               }
             }}

          {:delete, 3} ->
            {:ok, %{status: 200}}

          _ ->
            {:ok, %{status: 200}}
        end
      end

      assert :ok = IssueState.update_issue_state("42", "rework", request_fun: request_fun)

      # Two GETs, two DELETEs, no POST (closed race detected on second GET)
      assert_receive {:request, %{method: :get}}
      assert_receive {:request, %{method: :delete}}
      assert_receive {:request, %{method: :get}}
      assert_receive {:request, %{method: :delete}}
      refute_receive {:request, %{method: :post}}, 100
    end
  end

  describe "add_label/3" do
    test "returns :ok for 200..299 responses" do
      for status <- [200, 201, 204] do
        request_fun = fn _ -> {:ok, %{status: status}} end
        assert :ok = IssueState.add_label("42", "sym:watch", request_fun: request_fun)
      end
    end

    test "returns error for non-2xx responses" do
      request_fun = fn _ -> {:ok, %{status: 404, body: %{}, headers: []}} end
      assert {:error, _} = IssueState.add_label("42", "sym:watch", request_fun: request_fun)
    end
  end

  describe "remove_label/3" do
    test "treats 404 as success (idempotent delete)" do
      request_fun = fn _ -> {:ok, %{status: 404}} end
      assert :ok = IssueState.remove_label("42", "sym:todo", request_fun: request_fun)
    end

    test "returns :ok for 200" do
      request_fun = fn _ -> {:ok, %{status: 200}} end
      assert :ok = IssueState.remove_label("42", "sym:todo", request_fun: request_fun)
    end

    test "returns error for non-2xx/non-404 responses" do
      request_fun = fn _ -> {:ok, %{status: 500, body: %{}, headers: []}} end
      assert {:error, _} = IssueState.remove_label("42", "sym:todo", request_fun: request_fun)
    end
  end
end
