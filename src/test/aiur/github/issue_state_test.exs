defmodule Aiur.GitHub.IssueStateTest do
  # Cohesion: these tests cover the GitHub issue-state transition protocol end to end.
  use Aiur.TestSupport

  alias Aiur.GitHub.{Issues, IssueState}
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
    test "removes concurrent labels discovered after stale cached reads" do
      key = ResourceStore.key_for_repo(:issue, "owner/repo", "42")
      stale = %{"state" => "open", "labels" => [%{"name" => "sym:ci-wait"}]}
      live = %{"state" => "open", "labels" => [%{"name" => "sym:rework"}, %{"name" => "sym:human-review"}]}
      :ok = ResourceStore.put_resource(key, stale, etag: ~s("stale"))
      parent = self()
      reads = :ets.new(:issue_state_reads, [:set, :public])
      :ets.insert(reads, {:count, 0})
      request_fun = concurrent_state_request_fun(parent, reads, live)

      assert :ok = IssueState.update_issue_state("42", "in-progress", request_fun: request_fun)

      assert_receive {:request, %{method: :get, etag: ~s("stale")}}, 1000
      assert_receive {:request, %{method: :get, etag: ~s("stale")}}, 1000
      assert_receive {:request, %{method: :post, body: %{"labels" => ["sym:in-progress"]}}}, 1000
      assert_receive {:request, %{method: :get, etag: ~s("stale")}}, 1000
      assert_receive {:request, %{method: :delete, url: rework_url}}, 1000
      assert rework_url =~ "sym%3Arework" or rework_url =~ "sym:rework"
      assert_receive {:request, %{method: :delete, url: review_url}}, 1000
      assert review_url =~ "sym%3Ahuman-review" or review_url =~ "sym:human-review"
    end

    test "resumes cleanup when a local hold follows the target label add" do
      parent = self()
      request_counts = :ets.new(:held_issue_state_requests, [:set, :public])
      :ets.insert(request_counts, get: 0, post: 0, delete: 0)
      reset_at = DateTime.add(DateTime.utc_now(), -1, :second)
      rework = %{"state" => "open", "labels" => [%{"name" => "sym:rework"}]}
      both = %{"state" => "open", "labels" => [%{"name" => "sym:rework"}, %{"name" => "sym:in-progress"}]}
      request_fun = held_state_request_fun(parent, request_counts, reset_at, rework, both)

      assert :ok =
               IssueState.update_issue_state("42", "in-progress",
                 request_fun: request_fun,
                 expected_state: "rework",
                 local_hold_sleep_fun: fn _ -> :ok end
               )

      assert Map.new(:ets.tab2list(request_counts)) == %{get: 4, post: 1, delete: 2}
      assert_received {:held_state_request, %{method: :delete, url: deleted_label}}
      assert deleted_label =~ "sym%3Arework" or deleted_label =~ "sym:rework"
      assert_received {:held_state_request, %{method: :delete, url: ^deleted_label}}
    end

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

      # All issue reads on the transition carry the stored validator.
      assert_receive {:request, %{method: :get, etag: ~s("issue-etag")}}, 1000
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

      assert Enum.count(methods, &(&1 == :get)) == 3
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

      assert Enum.count(methods, &(&1 == :get)) == 3
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

    test "a failure after the target add rolls it back and preserves rework" do
      test_pid = self()
      calls = :ets.new(:rework_claim_swap_calls, [:set, :public])
      :ets.insert(calls, {:count, 0})
      rework = %{"state" => "open", "labels" => [%{"name" => "sym:rework"}]}
      both = %{"state" => "open", "labels" => [%{"name" => "sym:rework"}, %{"name" => "sym:in-progress"}]}
      labels = :ets.new(:rework_claim_labels, [:set, :public])
      :ets.insert(labels, {:value, ["sym:rework"]})

      request_fun = fn req ->
        send(test_pid, {:rework_swap_request, req})
        [{:count, n}] = :ets.lookup(calls, :count)
        :ets.insert(calls, {:count, n + 1})

        case {req.method, n} do
          {:get, n} when n in 0..2 ->
            {:ok, %{status: 200, body: rework}}

          {:post, 3} ->
            :ets.insert(labels, {:value, ["sym:rework", "sym:in-progress"]})
            {:ok, %{status: 200, body: both}}

          {:get, 4} ->
            {:ok, %{status: 200, body: both}}

          {:delete, 5} ->
            {:ok, %{status: 500, body: %{}, headers: []}}

          {:delete, 6} ->
            :ets.insert(labels, {:value, ["sym:rework"]})
            {:ok, %{status: 200, body: rework}}

          other ->
            flunk("unexpected rework state request: #{inspect(other)}")
        end
      end

      assert {:error, _reason} =
               IssueState.update_issue_state("42", "in-progress", expected_state: "rework", request_fun: request_fun)

      assert_received {:rework_swap_request, %{method: :post, body: %{"labels" => ["sym:in-progress"]}}}
      assert_received {:rework_swap_request, %{method: :delete, url: original_state_url}}
      assert original_state_url =~ "sym%3Arework" or original_state_url =~ "sym:rework"
      assert_received {:rework_swap_request, %{method: :delete, url: rollback_url}}
      assert rollback_url =~ "sym%3Ain-progress" or rollback_url =~ "sym:in-progress"
      assert [{:value, ["sym:rework"]}] = :ets.lookup(labels, :value)
      assert Issues.extract_state(rework, ["sym:rework"], "sym") == "rework"
    end

    test "the successful rework transition leaves only the in-progress state label" do
      test_pid = self()
      rework = %{"state" => "open", "labels" => [%{"name" => "sym:rework"}]}
      both = %{"state" => "open", "labels" => [%{"name" => "sym:rework"}, %{"name" => "sym:in-progress"}]}
      labels = :ets.new(:successful_rework_claim_labels, [:set, :public])
      :ets.insert(labels, {:value, ["sym:rework"]})

      request_fun = fn req ->
        send(test_pid, {:successful_rework_request, req})

        case req.method do
          :get ->
            {:ok, %{status: 200, body: if(:ets.lookup_element(labels, :value, 2) == ["sym:rework"], do: rework, else: both)}}

          :post ->
            :ets.insert(labels, {:value, ["sym:rework", "sym:in-progress"]})
            {:ok, %{status: 200, body: both}}

          :delete ->
            :ets.insert(labels, {:value, ["sym:in-progress"]})
            {:ok, %{status: 200, body: %{"labels" => [%{"name" => "sym:in-progress"}]}}}
        end
      end

      assert :ok = IssueState.update_issue_state("42", "in-progress", expected_state: "rework", request_fun: request_fun)
      assert [{:value, ["sym:in-progress"]}] = :ets.lookup(labels, :value)
      assert_received {:successful_rework_request, %{method: :post, body: %{"labels" => ["sym:in-progress"]}}}
      assert_received {:successful_rework_request, %{method: :delete, url: old_state_url}}
      assert old_state_url =~ "sym%3Arework" or old_state_url =~ "sym:rework"
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

          {:get, 3} ->
            {:ok,
             %{
               status: 200,
               body: %{"state" => "open", "labels" => [%{"name" => "sym:rework"}]}
             }}

          _ ->
            flunk("unexpected request after the target label was already present: #{inspect(req)}")
        end
      end

      assert :ok = IssueState.update_issue_state("42", "rework", request_fun: request_fun)

      assert_receive {:request, %{method: :get}}, 1000
      assert_receive {:request, %{method: :get}}, 1000
      assert_receive {:request, %{method: :post, body: %{"labels" => ["sym:rework"]}}}, 1000
      assert_receive {:request, %{method: :get}}, 1000
      # The just-added (already-present) label is excluded from the removal set,
      # so no DELETE ever fires and the ticket keeps exactly one state label.
      refute_receive {:request, %{method: :delete}}, 100
    end
  end

  defp concurrent_state_request_fun(parent, reads, live) do
    fn request ->
      send(parent, {:request, request})

      case request.method do
        :get ->
          concurrent_state_read(request, reads, live)

        :post ->
          assert request.body == %{"labels" => ["sym:in-progress"]}
          {:ok, %{status: 200}}

        :delete ->
          {:ok, %{status: 200}}
      end
    end
  end

  defp concurrent_state_read(request, reads, live) do
    assert request.etag == ~s("stale")
    read = :ets.update_counter(reads, :count, 1)

    if read < 3 do
      {:ok, %{status: 304}}
    else
      {:ok, %{status: 200, body: live, headers: [{"etag", ~s("live")}]}}
    end
  end

  defp held_state_request_fun(parent, request_counts, reset_at, rework, both) do
    fn request ->
      send(parent, {:held_state_request, request})
      count = :ets.update_counter(request_counts, request.method, 1)
      held_state_response(request, count, reset_at, rework, both)
    end
  end

  defp held_state_response(%{method: :get}, count, _reset_at, rework, both) do
    body = if count < 3, do: rework, else: both
    {:ok, %{status: 200, body: body}}
  end

  defp held_state_response(%{method: :post}, _count, _reset_at, _rework, _both) do
    {:ok, %{status: 200}}
  end

  defp held_state_response(%{method: :delete}, 1, reset_at, _rework, _both) do
    {:error, {:aiur, :locally_held, %{reset_at: reset_at}}}
  end

  defp held_state_response(%{method: :delete}, _count, _reset_at, _rework, _both) do
    {:ok, %{status: 200, body: [%{"name" => "sym:in-progress"}]}}
  end
end
