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
    test "swap keeps the queued marker" do
      test_pid = self()

      request_fun = fn request ->
        send(test_pid, {:queue_request, request})

        case request.method do
          :get ->
            {:ok, %{status: 200, body: %{"state" => "open", "labels" => [%{"name" => "sym:todo"}, %{"name" => "sym:queued"}]}}}

          :post ->
            assert request.body == %{"labels" => ["sym:in-progress"]}
            {:ok, %{status: 200}}

          :delete ->
            {:ok, %{status: 200}}
        end
      end

      assert :ok = IssueState.update_issue_state("42", "in-progress", request_fun: request_fun)
      assert_received {:queue_request, %{method: :delete, url: "https://api.github.com/repos/owner/repo/issues/42/labels/sym:todo"}}
      refute_received {:queue_request, %{method: :delete}}
    end

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
      assert_receive {:request, %{method: :get, etag: ~s("issue-etag")}}, 1000
      assert_receive {:request, %{method: :get, etag: ~s("issue-etag")}}, 1000
    end

    test "adds the new state label first, then removes the old one (no zero-label window)" do
      calls = :ets.new(:calls, [:set, :public])
      :ets.insert(calls, {:requests, []})

      request_fun = fn req ->
        [{:requests, seen}] = :ets.lookup(calls, :requests)
        :ets.insert(calls, {:requests, [req | seen]})

        # Responses are keyed by method + URL, not call ordinal: #2426 reorders
        # the swap to add-first, so a test that dispatches on the call index
        # silently falls through to a catch-all and asserts nothing. The two
        # GETs (initial read and the active-label re-check) both serve the
        # pre-swap label set; the transition removes the prefixed label(s) and
        # adds the target regardless of which order the POST/DELETEs land in.
        case req.method do
          :get ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "state" => "open",
                 "labels" => [%{"name" => "sym:todo"}, %{"name" => "other"}]
               }
             }}

          :delete ->
            assert req.url =~ "sym%3Atodo" or req.url =~ "sym:todo"
            {:ok, %{status: 200}}

          :post ->
            assert req.body == %{"labels" => ["sym:rework"]}
            {:ok, %{status: 200}}

          :patch ->
            flunk("non-terminal state must not close the issue")

          _other ->
            flunk("unexpected request: #{inspect(req)}")
        end
      end

      assert :ok = IssueState.update_issue_state("42", "rework", request_fun: request_fun)

      # Assert the resulting call *set*, not the ordinals: one initial read, one
      # active-label re-check, one removal of the old state label, one add of
      # the target — and no close (#2366, #2426).
      [{:requests, seen}] = :ets.lookup(calls, :requests)
      methods = Enum.map(seen, & &1.method)

      assert Enum.count(methods, &(&1 == :get)) == 2
      assert Enum.count(methods, &(&1 == :delete)) == 1
      assert Enum.count(methods, &(&1 == :post)) == 1
      refute :patch in methods
    end

    test "a second state label replaces the first rather than both persisting" do
      # #2366 acceptance: a state label set is an enum, not a set. A ticket
      # already carrying two `agent:*` state labels (here the stale ci-wait that
      # was never cleared plus rework) must end with exactly one label when a
      # transition applies the next one — both old labels are removed and only
      # the target is added.
      calls = :ets.new(:calls, [:set, :public])
      :ets.insert(calls, {:requests, []})

      request_fun = fn req ->
        [{:requests, seen}] = :ets.lookup(calls, :requests)
        :ets.insert(calls, {:requests, [req | seen]})

        case req.method do
          :get ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "state" => "open",
                 "labels" => [%{"name" => "sym:ci-wait"}, %{"name" => "sym:rework"}]
               }
             }}

          :delete ->
            {:ok, %{status: 200}}

          :post ->
            assert req.body == %{"labels" => ["sym:in-progress"]}
            {:ok, %{status: 200}}

          :patch ->
            flunk("non-terminal state must not close the issue")

          _other ->
            flunk("unexpected request: #{inspect(req)}")
        end
      end

      assert :ok = IssueState.update_issue_state("42", "in-progress", request_fun: request_fun)

      # Both old state labels were removed and the target added — asserted as a
      # call set so the swap order (#2426 add-first) cannot silently unset them.
      [{:requests, seen}] = :ets.lookup(calls, :requests)
      methods = Enum.map(seen, & &1.method)
      deleted_urls = Enum.map(Enum.filter(seen, &(&1.method == :delete)), & &1.url)

      assert Enum.count(methods, &(&1 == :get)) == 2
      assert Enum.count(methods, &(&1 == :delete)) == 2
      assert Enum.count(methods, &(&1 == :post)) == 1
      refute :patch in methods

      assert Enum.any?(deleted_urls, &(&1 =~ "sym%3Aci-wait" or &1 =~ "sym:ci-wait"))
      assert Enum.any?(deleted_urls, &(&1 =~ "sym%3Arework" or &1 =~ "sym:rework"))
    end

    # Acceptance #2420: a swap that fails on the new-label POST must never leave
    # the ticket with zero state labels. The swap adds first, so a failed POST
    # short-circuits before any DELETE — the old state label survives and the
    # ticket stays visible to dispatch. (Remove-then-add would have DELETEd the
    # old label first and stranded the ticket on the POST failure.)
    test "a failed new-label POST never leaves the ticket with zero state labels" do
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
               body: %{"state" => "open", "labels" => [%{"name" => "sym:todo"}]}
             }}

          {:get, 1} ->
            {:ok,
             %{
               status: 200,
               body: %{"state" => "open", "labels" => [%{"name" => "sym:todo"}]}
             }}

          {:post, 2} ->
            {:ok, %{status: 500, body: %{}, headers: []}}

          _ ->
            flunk("unexpected request after failed POST: #{inspect(req)}")
        end
      end

      assert {:error, _} = IssueState.update_issue_state("42", "rework", request_fun: request_fun)

      assert_receive {:request, %{method: :get}}, 1000
      assert_receive {:request, %{method: :get}}, 1000
      assert_receive {:request, %{method: :post}}, 1000
      # No DELETE ever fires: the old sym:todo label is never removed, so the
      # issue never passes through a zero-state-label state.
      refute_receive {:request, %{method: :delete}}, 100
    end

    # Acceptance #2420: an idempotent re-stamp — `update_issue_state(id, "rework")`
    # on a ticket already carrying `sym:rework` — must not delete the only state
    # label. The swap POSTs the target first (a no-op) and the removal set
    # excludes the just-added label, so the DELETE must never fire. Without that
    # exclusion, the swap would POST a no-op and then delete the only state
    # label — the original remove-then-add strand, reintroduced under the new
    # ordering.
    test "a re-stamp of the current state label never deletes it (exclude guard)" do
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
               body: %{"state" => "open", "labels" => [%{"name" => "sym:rework"}]}
             }}

          {:get, 1} ->
            {:ok,
             %{
               status: 200,
               body: %{"state" => "open", "labels" => [%{"name" => "sym:rework"}]}
             }}

          {:post, 2} ->
            assert req.body == %{"labels" => ["sym:rework"]}
            {:ok, %{status: 200}}

          _ ->
            flunk("unexpected request after the target label was already present: #{inspect(req)}")
        end
      end

      assert :ok = IssueState.update_issue_state("42", "rework", request_fun: request_fun)

      assert_receive {:request, %{method: :get}}, 1000
      assert_receive {:request, %{method: :get}}, 1000
      assert_receive {:request, %{method: :post, body: %{"labels" => ["sym:rework"]}}}, 1000
      # The just-added (already-present) label is excluded from the removal set,
      # so no DELETE ever fires and the ticket keeps exactly one state label.
      refute_receive {:request, %{method: :delete}}, 100
    end
  end
end
