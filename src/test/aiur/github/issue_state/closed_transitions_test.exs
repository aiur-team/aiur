defmodule Aiur.GitHub.IssueState.ClosedTransitionsTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.IssueState
  alias Aiur.GitHub.ResourceStore

  @token_cache_key {Aiur.GitHub.Access.Token, :resolved_token}

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
    test "future regression guard: terminal target adds done before removing old state" do
      calls = :ets.new(:calls, [:set, :public])
      :ets.insert(calls, {:count, 0})

      request_fun = fn req ->
        [{:count, n}] = :ets.lookup(calls, :count)
        :ets.insert(calls, {:count, n + 1})

        case {req.method, n} do
          {:get, 0} ->
            send(self(), {:state_write_method, :get})

            {:ok,
             %{
               status: 200,
               body: %{"state" => "open", "labels" => [%{"name" => "sym:in-progress"}]}
             }}

          {:post, 1} ->
            send(self(), {:state_write_method, :post})
            assert req.body == %{"labels" => ["sym:done"]}
            {:ok, %{status: 200}}

          {:get, 2} ->
            send(self(), {:state_write_method, :get})

            {:ok,
             %{
               status: 200,
               body: %{
                 "state" => "open",
                 "labels" => [%{"name" => "sym:done"}, %{"name" => "sym:in-progress"}]
               }
             }}

          {:delete, 3} ->
            send(self(), {:state_write_method, :delete})
            {:ok, %{status: 200}}

          {:patch, 4} ->
            send(self(), {:state_write_method, :patch})
            assert req.body == %{"state" => "closed"}
            {:ok, %{status: 200}}

          _ ->
            {:ok, %{status: 200}}
        end
      end

      assert :ok = IssueState.update_issue_state("42", "Done", request_fun: request_fun)

      assert for(
               _ <- 1..5,
               do:
                 receive do
                   {:state_write_method, method} -> method
                 end
             ) ==
               [:get, :post, :get, :delete, :patch]
    end

    test "closed-issue active-target branch preserves done while removing stale active labels" do
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

          :post ->
            assert req.body == %{"labels" => ["sym:done"]}
            {:ok, %{status: 200, body: [%{"name" => "sym:done"}]}}

          :delete ->
            {:ok, %{status: 200, body: []}}

          _ ->
            {:ok, %{status: 200}}
        end
      end

      # The target is an active state on a closed issue, so no active state
      # label was written — the transition must report that honestly instead
      # of a false `:ok` (#2420).
      assert {:error, {:no_state_label_written, _issue}} =
               IssueState.update_issue_state("42", "rework", request_fun: request_fun)

      # The terminal label is already present, so only stale active labels are
      # removed. It does not POST the requested active label or PATCH the
      # already-closed issue.
      assert_receive {:request, %{method: :get}}, 1000
      assert_receive {:request, %{method: :delete}}, 1000
      assert_receive {:request, %{method: :delete}}, 1000
      refute_receive {:request, %{method: :post}}, 100
      refute_receive {:request, %{method: :patch}}, 100
    end

    test "closed zero-label issue gets done before stale active labels are removed" do
      test_pid = self()

      request_fun = fn req ->
        send(test_pid, {:request, req})

        case req.method do
          :get ->
            {:ok,
             %{
               status: 200,
               body: %{"state" => "closed", "labels" => [%{"name" => "sym:rework"}]}
             }}

          :post ->
            assert req.body == %{"labels" => ["sym:done"]}
            {:ok, %{status: 200}}

          _ ->
            {:ok, %{status: 200}}
        end
      end

      assert {:error, {:no_state_label_written, _issue}} =
               IssueState.update_issue_state("42", "rework", request_fun: request_fun)

      assert_receive {:request, %{method: :get}}, 1000
      assert_receive {:request, %{method: :post, body: %{"labels" => ["sym:done"]}}}, 1000
      assert_receive {:request, %{method: :delete}}, 1000
      refute_receive {:request, %{method: :post}}, 100
    end

    test "closed cancelled issue keeps its existing terminal label" do
      test_pid = self()

      request_fun = fn req ->
        send(test_pid, {:request, req})

        case req.method do
          :get ->
            {:ok, %{status: 200, body: %{"state" => "closed", "labels" => [%{"name" => "sym:cancelled"}, %{"name" => "sym:rework"}]}}}

          :delete ->
            {:ok, %{status: 200, body: [%{"name" => "sym:cancelled"}]}}

          method ->
            flunk("unexpected #{method} for a closed cancelled issue")
        end
      end

      assert {:error, {:no_state_label_written, %{"labels" => [%{"name" => "sym:cancelled"}]}}} =
               IssueState.update_issue_state("42", "rework", request_fun: request_fun)

      assert_received {:request, %{method: :get}}
      assert_received {:request, %{method: :delete}}
      refute_received {:request, %{method: :post}}
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

          {:get, 1} ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "state" => "closed",
                 "labels" => [%{"name" => "sym:done"}, %{"name" => "sym:rework"}]
               }
             }}

          {:delete, 2} ->
            {:ok, %{status: 200}}

          _ ->
            {:ok, %{status: 200}}
        end
      end

      # The active-label add is the first step of the swap; it discovers the
      # issue is closed, sees the existing done label, strips the stale active
      # label, and reports that no active state label was written (#2420).
      assert {:error, {:no_state_label_written, _issue}} =
               IssueState.update_issue_state("42", "rework", request_fun: request_fun)

      # Two GETs then DELETE the stale rework label. The existing done label
      # makes another POST unnecessary.
      assert_receive {:request, %{method: :get}}, 1000
      assert_receive {:request, %{method: :get}}, 1000
      assert_receive {:request, %{method: :delete}}, 1000
      refute_receive {:request, %{method: :post}}, 100
    end
  end
end
