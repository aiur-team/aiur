defmodule Aiur.Events.GithubFirehoseRetryTest do
  use Aiur.TestSupport

  alias Aiur.Events.{Exchange, GithubFirehose, Publisher}
  alias Aiur.Workflow

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "aiur"
    )

    Publisher.set_tracked_fn(fn _ -> true end)

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", prev_token)
      Publisher.set_tracked_fn(fn _ -> true end)

      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end
    end)

    {:ok, ticket: Integer.to_string(System.unique_integer([:positive]))}
  end

  describe "poll/1" do
    test "a closing keyword on a non-ticket branch routes an opened PR" do
      :ok = Exchange.subscribe("ticket.5605.pr.opened")

      stub = fn _ ->
        {:ok,
         %{
           status: 200,
           headers: [{"ETag", ~s("closing-open")}],
           body: [
             %{
               "id" => "closing-open",
               "type" => "PullRequestEvent",
               "actor" => %{"login" => "carol"},
               "repo" => %{"name" => "owner/repo"},
               "payload" => %{
                 "action" => "opened",
                 "pull_request" => %{
                   "number" => 5606,
                   "body" => "Closes #5605",
                   "head" => %{"ref" => "executor/patch", "sha" => String.duplicate("e", 40)}
                 }
               }
             }
           ]
         }}
      end

      assert {:ok, %{count: 1}} = GithubFirehose.poll(request_fun: stub)
      assert_receive {:event, %{topic: "ticket.5605.pr.opened"}}, 500
    end

    test "a failed commit lookup preserves branch attribution and advances the cursor" do
      :ok = Exchange.subscribe("ticket.42.pr.opened")
      :ok = Exchange.subscribe("ticket.43.pr.opened")
      :ok = Exchange.subscribe("ticket.5605.pr.merged")

      stub = fn %{url: url} ->
        if String.contains?(url, "/pulls/5606/commits") do
          {:error, :offline}
        else
          {:ok,
           %{
             status: 200,
             headers: [{"ETag", ~s("new-etag")}],
             body: [
               opened_event("newer-open", 42, "aiur/42-fix"),
               %{
                 "id" => "commit-only-reference-merge",
                 "type" => "PullRequestEvent",
                 "created_at" => DateTime.to_iso8601(DateTime.utc_now()),
                 "actor" => %{"login" => "carol"},
                 "repo" => %{"name" => "owner/repo"},
                 "payload" => %{
                   "action" => "merged",
                   "pull_request" => %{
                     "number" => 5606,
                     "body" => "Maintenance change",
                     "merged" => true,
                     "head" => %{"ref" => "aiur/5605-fix", "sha" => String.duplicate("c", 40)}
                   }
                 }
               },
               opened_event("older-open", 43, "aiur/43-fix")
             ]
           }}
        end
      end

      assert {:ok,
              %{
                count: 3,
                etag: ~s("new-etag"),
                last_event_id: "newer-open",
                recent_merge_persistence: :ok
              }} =
               GithubFirehose.poll(
                 request_fun: stub,
                 etag: "previous-etag",
                 last_event_id: "previous-event",
                 boot_time: DateTime.add(DateTime.utc_now(), -3600, :second) |> DateTime.to_unix()
               )

      assert_receive {:event, %{topic: "ticket.5605.pr.merged"}}, 500
      assert_receive {:event, %{topic: "ticket.43.pr.opened"}}, 500
      assert_receive {:event, %{topic: "ticket.42.pr.opened"}}, 500
    end

    test "a permanently oversized commit list advances the cursor without ticket attribution" do
      :ok = Exchange.subscribe("ticket.5605.pr.merged")
      page_count = :atomics.new(1, [])

      stub = fn %{url: url} ->
        if String.contains?(url, "/pulls/998887/commits") do
          page = :atomics.add_get(page_count, 1, 1)
          next_url = "https://api.github.com/repos/owner/repo/pulls/998887/commits?per_page=100&page=#{page + 1}"
          headers = if page <= 100, do: [{"link", "<#{next_url}>; rel=\"next\""}], else: []
          {:ok, %{status: 200, headers: headers, body: [%{"commit" => %{"message" => "Refs #5605"}}]}}
        else
          {:ok,
           %{
             status: 200,
             headers: [{"ETag", ~s("permanent-overflow")}],
             body: [
               %{
                 "id" => "permanent-overflow",
                 "type" => "PullRequestEvent",
                 "created_at" => DateTime.to_iso8601(DateTime.utc_now()),
                 "actor" => %{"login" => "carol"},
                 "repo" => %{"name" => "owner/repo"},
                 "payload" => %{
                   "action" => "merged",
                   "pull_request" => %{
                     "number" => 998_887,
                     "body" => "Refs #5605",
                     "merged" => true,
                     "head" => %{"ref" => "aiur/5605-fix", "sha" => String.duplicate("d", 40)}
                   }
                 }
               }
             ]
           }}
        end
      end

      assert {:ok, %{count: 1, last_event_id: "permanent-overflow", etag: ~s("permanent-overflow")}} =
               GithubFirehose.poll(request_fun: stub)

      assert :atomics.get(page_count, 1) == 100
      assert_receive {:event, %{topic: "ticket.5605.pr.merged"}}, 500
    end

    test "an unclassified merge advances the cursor when commit lookup fails" do
      :ok = Exchange.subscribe("ticket.5605.pr.merged")

      stub = fn
        %{url: url} when is_binary(url) ->
          if String.contains?(url, "/pulls/5607/commits") do
            {:error, :offline}
          else
            {:ok,
             %{
               status: 200,
               headers: [{"ETag", ~s("unclassified-merge")}],
               body: [
                 %{
                   "id" => "unclassified-merge",
                   "type" => "PullRequestEvent",
                   "created_at" => DateTime.to_iso8601(DateTime.utc_now()),
                   "repo" => %{"name" => "owner/repo"},
                   "payload" => %{
                     "action" => "merged",
                     "pull_request" => %{
                       "number" => 5607,
                       "body" => "Refs #5605",
                       "merged" => true,
                       "head" => %{"ref" => "executor/quarantine", "sha" => "unclassified-head"}
                     }
                   }
                 }
               ]
             }}
          end

        _request ->
          flunk("the merge event request should be the only other request")
      end

      assert {:ok, %{count: 0, last_event_id: "unclassified-merge", etag: ~s("unclassified-merge")}} =
               GithubFirehose.poll(request_fun: stub)

      refute_receive {:event, %{topic: "ticket.5605.pr.merged"}}, 100
    end

    test "a closing keyword routes a merged PR when commit evidence cannot be fetched" do
      :ok = Exchange.subscribe("ticket.5605.pr.merged")

      stub = fn %{url: url} ->
        if String.contains?(url, "/pulls/5606/commits") do
          {:error, :offline}
        else
          {:ok,
           %{
             status: 200,
             headers: [{"ETag", ~s("close-merge")}],
             body: [
               %{
                 "id" => "close-merge",
                 "type" => "PullRequestEvent",
                 "created_at" => "2026-07-12T17:59:00Z",
                 "actor" => %{"login" => "carol"},
                 "repo" => %{"name" => "owner/repo"},
                 "payload" => %{
                   "action" => "merged",
                   "pull_request" => %{"number" => 5606, "body" => "Closes #5605", "merged" => true, "head" => %{"ref" => "executor/patch", "sha" => String.duplicate("b", 40)}}
                 }
               }
             ]
           }}
        end
      end

      assert {:ok, %{count: 1}} = GithubFirehose.poll(request_fun: stub, boot_time: ~U[2026-07-12 18:00:00Z] |> DateTime.to_unix())
      assert_receive {:event, %{topic: "ticket.5605.pr.merged"}}, 500
    end
  end

  defp opened_event(id, ticket, branch) do
    %{
      "id" => id,
      "type" => "PullRequestEvent",
      "actor" => %{"login" => "carol"},
      "repo" => %{"name" => "owner/repo"},
      "payload" => %{
        "action" => "opened",
        "pull_request" => %{
          "number" => ticket,
          "head" => %{"ref" => branch, "sha" => String.duplicate("a", 40)}
        }
      }
    }
  end
end
