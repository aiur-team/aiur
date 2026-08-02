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

    test "rejects done for hardware criteria until the operator signs off" do
      test_pid = self()

      request_fun = fn request ->
        send(test_pid, {:request, request})

        {:ok,
         %{
           status: 200,
           body: %{
             "state" => "open",
             "body" => "## Acceptance\n- Run sudo systemctl restart and press the device button.",
             "labels" => [%{"name" => "sym:in-progress"}, %{"name" => "sym:operator-verification-required"}]
           }
         }}
      end

      assert {:error, {:operator_signoff_required, detail}} =
               IssueState.update_issue_state("42", "done", request_fun: request_fun)

      assert detail.verified_label == "sym:operator-verified"
      assert_received {:request, %{method: :get}}
      refute_receive {:request, %{method: _method}}, 100
    end

    test "allows done after the operator applies the sign-off marker" do
      calls = :ets.new(:calls, [:set, :public])
      :ets.insert(calls, {:count, 0})

      request_fun = fn request ->
        [{:count, count}] = :ets.lookup(calls, :count)
        :ets.insert(calls, {:count, count + 1})

        case {request.method, count} do
          {:get, 0} ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "state" => "open",
                 "body" => "## Acceptance\n- Verify /dev/hidraw0 works after a replug.",
                 "labels" => [%{"name" => "sym:in-progress"}, %{"name" => "sym:operator-verified"}, %{"name" => "sym:operator-verification-passed"}]
               }
             }}

          {:get, 1} ->
            {:ok,
             %{
               status: 200,
               headers: [],
               body: [
                 %{
                   "event" => "labeled",
                   "id" => 1,
                   "created_at" => "2026-08-01T00:00:00Z",
                   "actor" => %{"login" => "operator"},
                   "label" => %{"name" => "sym:operator-verified"}
                 },
                 %{
                   "event" => "labeled",
                   "id" => 2,
                   "created_at" => "2026-08-01T00:01:00Z",
                   "actor" => %{"login" => "operator"},
                   "label" => %{"name" => "sym:operator-verification-passed"}
                 }
               ]
             }}

          {:delete, _} ->
            {:ok, %{status: 200}}

          {:post, _} ->
            {:ok, %{status: 200}}

          {:patch, _} ->
            {:ok, %{status: 200}}
        end
      end

      assert :ok =
               IssueState.update_issue_state("42", "done",
                 request_fun: request_fun,
                 operator_authorized?: &(&1 == "operator")
               )
    end

    test "rejects a sign-off marker whose GitHub label event was not applied by an operator" do
      request_fun = fn request ->
        cond do
          request.method == :get and String.contains?(request.url, "/timeline?") ->
            {:ok,
             %{
               status: 200,
               headers: [],
               body: [
                 %{
                   "event" => "labeled",
                   "id" => 1,
                   "created_at" => "2026-08-01T00:00:00Z",
                   "actor" => %{"login" => "operator"},
                   "label" => %{"name" => "sym:operator-verified"}
                 },
                 %{
                   "event" => "labeled",
                   "id" => 2,
                   "created_at" => "2026-08-01T00:01:00Z",
                   "actor" => %{"login" => "agent-bot"},
                   "label" => %{"name" => "sym:operator-verification-passed"}
                 }
               ]
             }}

          request.method == :get ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "state" => "open",
                 "body" => "## Acceptance\n- Verify /dev/hidraw0 works after a replug.",
                 "labels" => [%{"name" => "sym:in-progress"}, %{"name" => "sym:operator-verified"}, %{"name" => "sym:operator-verification-passed"}]
               }
             }}
        end
      end

      assert {:error, {:operator_signoff_event_required, :untrusted_actor}} =
               IssueState.update_issue_state("42", "done",
                 request_fun: request_fun,
                 operator_authorized?: &(&1 == "operator")
               )
    end

    test "posts one CI blind-spot notice when hardware work enters human review" do
      test_pid = self()

      request_fun = fn request ->
        send(test_pid, {:request, request})

        cond do
          request.method == :get and String.contains?(request.url, "/issues/42") ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "state" => "open",
                 "body" => "## Acceptance\n- Verify /dev/hidraw0 after pressing the dial.",
                 "labels" => [%{"name" => "sym:ci-wait"}, %{"name" => "sym:operator-verification-required"}]
               }
             }}

          request.method == :get and String.contains?(request.url, "/pulls?") ->
            {:ok, %{status: 200, body: [%{"number" => 77}], headers: []}}

          request.method == :post and is_binary(request.body["query"]) and request.body["query"] =~ "AiurViewerLogin" ->
            {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"login" => "aiur-bot"}}}}}

          request.method == :post and is_binary(request.body["query"]) and request.body["query"] =~ "AiurUnaddressedReviewThreads" ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "data" => %{
                   "repository" => %{
                     "pullRequest" => %{
                       "reviewThreads" => %{"pageInfo" => %{"hasNextPage" => false}, "nodes" => []}
                     }
                   }
                 }
               }
             }}

          request.method == :get and String.contains?(request.url, "/issues/77/comments?") ->
            {:ok, %{status: 200, body: []}}

          request.method == :post and String.contains?(request.url, "/issues/77/comments") ->
            assert request.body["body"] =~ "Hardware verification required"
            assert request.body["body"] =~ "sym:operator-verified"
            assert request.body["body"] =~ "sym:operator-verification-passed"
            assert request.body["body"] =~ "sym:operator-verification-no-go"
            {:ok, %{status: 201}}

          request.method in [:delete, :post] ->
            {:ok, %{status: 200}}
        end
      end

      assert :ok = IssueState.update_issue_state("42", "human-review", request_fun: request_fun)
      assert_received {:request, %{method: :post, url: url, body: %{"body" => body}}}
      assert url =~ "/issues/77/comments"
      assert body =~ "aiur:hardware-verification-required"
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
      assert_receive {:request, %{method: :get, url: legacy_pull_url}}
      assert legacy_pull_url =~ "/pulls?"
      assert_receive {:request, %{method: :get, url: ticket_pull_url}}
      assert ticket_pull_url =~ "/pulls?"
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
