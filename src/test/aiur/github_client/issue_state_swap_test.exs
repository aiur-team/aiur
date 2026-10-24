defmodule Aiur.GitHub.Client.IssueStateSwapTest do
  use Aiur.TestSupport

  import Aiur.GitHub.ClientTestSupport

  alias Aiur.GitHub.Client

  @tested_head String.duplicate("a", 40)
  @base_sha String.duplicate("b", 40)

  setup do
    setup_client()
  end

  describe "update_issue_state/3 label swaps" do
    test "state swaps preserve paused and watch marker labels" do
      test_pid = self()
      calls = :ets.new(:calls, [:set, :public])
      :ets.insert(calls, {:count, 0})

      request_fun = fn req ->
        send(test_pid, {:github_request, req})
        [{:count, n}] = :ets.lookup(calls, :count)
        :ets.insert(calls, {:count, n + 1})

        case {req.method, n} do
          {:get, 0} ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "state" => "open",
                 "labels" => [
                   %{"name" => "sym:paused"},
                   %{"name" => "sym:todo"},
                   %{"name" => "sym:watch"}
                 ]
               }
             }}

          {:get, 1} ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "state" => "open",
                 "labels" => [
                   %{"name" => "sym:paused"},
                   %{"name" => "sym:todo"},
                   %{"name" => "sym:watch"}
                 ]
               }
             }}

          {:post, 2} ->
            assert req.body == %{"labels" => ["sym:rework"]}
            {:ok, %{status: 200}}

          # State swaps re-read labels after adding the target so concurrent
          # state writes are included in the removal set.
          {:get, 3} ->
            assert req.url =~ "/issues/42"
            open_issue_response(["sym:paused", "sym:todo", "sym:rework", "sym:watch"])

          {:delete, 4} ->
            assert req.url =~ "sym:todo" or req.url =~ "sym%3Atodo"
            {:ok, %{status: 200}}
        end
      end

      assert :ok = Client.update_issue_state("42", "rework", request_fun: request_fun)

      assert_receive {:github_request, %{method: :get}}, 1000
      assert_receive {:github_request, %{method: :get}}, 1000
      assert_receive {:github_request, %{method: :post, body: %{"labels" => ["sym:rework"]}}}, 1000
      assert_receive {:github_request, %{method: :delete, url: deleted_url}}, 1000
      refute deleted_url =~ "sym:paused"
      refute deleted_url =~ "sym:watch"
      refute_receive {:github_request, %{method: :delete}}, 100
    end

    test "allows human-review when the open PR has no unaddressed review threads" do
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
                 "labels" => [%{"name" => "sym:in-progress"}]
               }
             }}

          {:get, 1} ->
            assert req.url =~ "/pulls?"
            {:ok, %{status: 200, body: [pr()]}}

          {:post, 2} ->
            assert req.url == "https://api.github.com/graphql"
            review_threads_page_response([])

          # The swap adds first: the active-label add re-checks the issue, then
          # POSTs the new label, then removes the old one (#2420).
          {:get, 3} ->
            assert req.url =~ "/compare/main...#{@tested_head}"
            {:ok, %{status: 200, body: %{"status" => "ahead"}}}

          {:get, 4} ->
            assert req.url =~ "/issues/42"

            {:ok,
             %{
               status: 200,
               body: %{
                 "state" => "open",
                 "labels" => [%{"name" => "sym:in-progress"}]
               }
             }}

          {:post, 5} ->
            assert req.body == %{"labels" => ["sym:human-review"]}
            {:ok, %{status: 200}}

          {:get, 6} ->
            assert req.url =~ "/issues/42"
            open_issue_response(["sym:in-progress", "sym:human-review"])

          {:delete, 7} ->
            assert req.url =~ "sym:in-progress" or req.url =~ "sym%3Ain-progress"
            {:ok, %{status: 200}}
        end
      end

      assert :ok =
               Client.update_issue_state("42", "human-review",
                 request_fun: request_fun,
                 bot_account: "aiur-bot"
               )
    end
  end

  defp open_issue_response(labels) do
    {:ok, %{status: 200, body: %{"state" => "open", "labels" => Enum.map(labels, &%{"name" => &1})}}}
  end

  defp pr do
    body = "## Local tests\n\nPolicy: partial\nTested head: #{@tested_head}\nBase: main @ #{@base_sha}\nSelection: focused gate coverage\n- `mix test` -> passed\n"
    %{"number" => 77, "body" => body, "head" => %{"ref" => "aiur/42", "sha" => @tested_head}}
  end
end
