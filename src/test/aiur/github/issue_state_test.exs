defmodule Aiur.GitHub.IssueStateTest do
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
    # Acceptance #2326: a state transition issues a conditional request. When the
    # store holds the issue body and its validator, the transition's own issue
    # read sends `If-None-Match` — a free `304` when nothing changed, instead of
    # the unconditional full-price read it used to make.
    test "the transition's issue read sends If-None-Match from the store's validator" do
      key = ResourceStore.key_for_repo(:issue, "owner/repo", "42")

      ResourceStore.put_resource(
        key,
        %{"state" => "open", "labels" => [%{"name" => "sym:todo"}]},
        source: :webhook,
        version: "2026-06-24T10:00:00Z",
        etag: ~s("issue-etag")
      )

      test_pid = self()

      request_fun = fn request ->
        send(test_pid, {:request, request})

        if request.method == :get do
          assert request.etag == ~s("issue-etag"), "the transition's issue read must send If-None-Match"
          {:ok, %{status: 200, body: %{"state" => "open", "labels" => [%{"name" => "sym:todo"}]}}}
        else
          {:ok, %{status: 200}}
        end
      end

      assert :ok = IssueState.update_issue_state("42", "rework", request_fun: request_fun)

      # Both issue reads on the transition (the initial and the active-label
      # re-check) carried the stored validator.
      assert_receive {:request, %{method: :get, etag: ~s("issue-etag")}}
      assert_receive {:request, %{method: :get, etag: ~s("issue-etag")}}
    end

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

      assert_receive {:request, %{method: :get}}
      refute_receive {:request, %{method: _method}}, 100
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
            state = if count == 0, do: "ci-wait", else: "rework"

            {:ok,
             %{
               status: 200,
               body: %{
                 "state" => "open",
                 "labels" => [%{"name" => "sym:#{state}"}]
               }
             }}

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

      assert_receive {:request, %{method: :get, url: issue_url}}
      assert issue_url =~ "/issues/42"
      # One open-pull-request listing, not two: the `head=<owner>:aiur/42` probe
      # that used to run in front of it matched only branches the listing's own
      # filter already accepts, so it was a billed request that answered nothing
      # the next one did not.
      assert_receive {:request, %{method: :get, url: ticket_pull_url}}
      assert ticket_pull_url =~ "/pulls?"
      refute ticket_pull_url =~ "head="
      assert_receive {:request, %{method: :get, url: ^issue_url}}
      refute_receive {:request, %{method: _method}}, 100
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

  describe "preserved_prefixed_label?/2" do
    test "preserves automatic fallback markers across workflow state changes" do
      assert IssueState.preserved_prefixed_label?("sym:rate-limit-fallback", "sym")
      assert IssueState.preserved_prefixed_label?(" SYM:RATE-LIMIT-FALLBACK ", "sym")
      refute IssueState.preserved_prefixed_label?("sym:in-progress", "sym")
    end
  end
end
