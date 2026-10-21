defmodule Aiur.Regression.GithubIngestion.DedupAndCutoffTest do
  use Aiur.TestSupport

  alias Aiur.Events.Exchange
  alias Aiur.Events.GithubCommentsPoller
  alias Aiur.Events.GithubFirehose
  alias Aiur.Events.GithubKeys
  alias Aiur.Events.Publisher

  alias Aiur.GitHub.CodeOwners

  setup do
    # Isolate the per-issue/alert log to a tmp dir: this file exercises
    # `src/lib/aiur/events`, whose publishes record IssueLog/alert markers.
    tmp_dir =
      Aiur.TestSupport.tmp_root!("aiur_github_ingestion_test")

    File.mkdir_p!(tmp_dir)
    original_log_file = Application.get_env(:aiur, :log_file)
    Application.put_env(:aiur, :log_file, Path.join(tmp_dir, "aiur.log"))

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

      if original_log_file do
        Application.put_env(:aiur, :log_file, original_log_file)
      else
        Application.delete_env(:aiur, :log_file)
      end

      # Tolerant rm_rf: matches the `Aiur.TestCleanup.rm_rf!/1` teardown convention in
      # `Aiur.TestSupport`; the dir is unique per test so a rare leftover is
      # harmless.
      Aiur.TestCleanup.rm_rf!(tmp_dir)
    end)

    :ok
  end

  describe "comment dedup keys vs the 1h Publisher TTL" do
    test "second poll of the same issue comment id is deduped" do
      target = Integer.to_string(System.unique_integer([:positive]))
      repo = "owner/repo-#{System.unique_integer([:positive])}"
      id = System.unique_integer([:positive])

      request_fun = fn %{url: url} ->
        cond do
          String.contains?(url, "/issues/#{target}/comments?") ->
            {:ok, %{status: 200, body: [issue_comment(id, "alice", "hello", "2026-07-01T12:00:00Z")]}}

          String.contains?(url, "/pulls?") ->
            {:ok, %{status: 200, body: []}}
        end
      end

      :ok = Exchange.subscribe("ticket.#{target}.issue.commented")

      assert {:ok, %{count: 1}} =
               GithubCommentsPoller.poll([target],
                 since: "2026-07-01T00:00:00Z",
                 repo: repo,
                 request_fun: request_fun
               )

      assert_receive {:event, %{topic: topic}}, 2000
      assert topic == "ticket.#{target}.issue.commented"

      # Same (repo, "issue_comment", parent, id) triple within the 1h TTL.
      assert {:ok, %{count: 0}} =
               GithubCommentsPoller.poll([target],
                 since: "2026-07-01T00:00:00Z",
                 repo: repo,
                 request_fun: request_fun
               )

      refute_received {:event, _}
    end

    test "review-thread wake dedups on the stable thread node id" do
      target = Integer.to_string(System.unique_integer([:positive]))
      repo = "owner/repo-#{System.unique_integer([:positive])}"
      thread_id = "PRRT_t2_#{System.unique_integer([:positive])}"
      codeowners = ensure_codeowners!("* @its-everdred\n")
      on_exit(fn -> stop_codeowners(codeowners) end)

      request_fun = fn %{url: url} ->
        cond do
          String.contains?(url, "/graphql") ->
            review_threads_response([
              %{
                "id" => thread_id,
                "isResolved" => false,
                "path" => "lib/app.ex",
                "line" => 12,
                "comments" => %{"nodes" => [review_thread_comment(2102, "its-everdred", "unresolved")]}
              }
            ])

          String.contains?(url, "/reviews") ->
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/issues/") ->
            {:ok, %{status: 200, body: []}}
        end
      end

      opts = [
        since: "2026-07-01T00:00:00Z",
        repo: repo,
        request_fun: request_fun,
        open_pull_requests_by_target: %{target => %{"number" => 77}}
      ]

      # Dedup key is review_thread_dedup_key(repo, 77, thread_id) — the thread
      # node id, NOT the comment id.
      assert {:ok, %{count: 1}} = GithubCommentsPoller.poll([target], opts)
      assert {:ok, %{count: 0}} = GithubCommentsPoller.poll([target], opts)
    end

    test "malformed dedup_key never blocks publishing" do
      target = Integer.to_string(System.unique_integer([:positive]))

      # A partial (non 3-binary-tuple) key drops the dedup signal instead of
      # crashing or deduping — both publishes succeed.
      assert {:ok, _, _} =
               Publisher.publish("ticket.#{target}.issue.commented", %{n: 1},
                 issue_number: target,
                 dedup_key: {:bad, :key}
               )

      assert {:ok, _, _} =
               Publisher.publish("ticket.#{target}.issue.commented", %{n: 1},
                 issue_number: target,
                 dedup_key: {:bad, :key}
               )
    end

    test "dedup TTL is pinned at 1 hour" do
      # The app supervision tree starts the Publisher singleton before tests
      # run, so the key must exist (no default argument). Shrinking this window
      # re-introduces duplicate pr.opened/issue.commented storms (FI-EVT-011).
      assert :persistent_term.get({Publisher, :ttl_ms}) == 3_600_000
    end
  end

  describe "boot cutoff never hides pre-boot unresolved review threads (#642 class)" do
    test "pre-boot unresolved review thread still publishes a wake" do
      boot_time = 1_782_302_400
      target = Integer.to_string(System.unique_integer([:positive]))
      repo = "owner/repo-#{System.unique_integer([:positive])}"
      thread_id = "PRRT_t5_#{System.unique_integer([:positive])}"
      codeowners = ensure_codeowners!("* @its-everdred\n")
      on_exit(fn -> stop_codeowners(codeowners) end)

      pre_boot_comment =
        2105
        |> review_thread_comment("its-everdred", "pre-boot unresolved thread")
        |> Map.merge(%{"createdAt" => "2020-01-01T00:00:00Z", "updatedAt" => "2020-01-01T00:00:00Z"})

      request_fun = fn %{url: url} ->
        cond do
          String.contains?(url, "/graphql") ->
            review_threads_response([
              %{
                "id" => thread_id,
                "isResolved" => false,
                "path" => "lib/app.ex",
                "line" => 3,
                "comments" => %{"nodes" => [pre_boot_comment]}
              }
            ])

          String.contains?(url, "/reviews") ->
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/issues/") ->
            {:ok, %{status: 200, body: []}}
        end
      end

      :ok = Exchange.subscribe("ticket.#{target}.pr.review_comment")

      # The review-thread endpoint takes NO since cursor, so the boot cutoff
      # cannot suppress a years-old unresolved thread.
      assert {:ok, %{count: 1}} =
               GithubCommentsPoller.poll([target],
                 boot_time: boot_time,
                 repo: repo,
                 request_fun: request_fun,
                 open_pull_requests_by_target: %{target => %{"number" => 88}}
               )

      assert_receive {:event, %{topic: topic}}, 2000
      assert topic == "ticket.#{target}.pr.review_comment"
    end

    test "issue-comment polling defaults since to boot cutoff (boot - 60s)" do
      boot_time = 1_782_302_400
      target = Integer.to_string(System.unique_integer([:positive]))
      repo = "owner/repo-#{System.unique_integer([:positive])}"
      parent = self()

      request_fun = fn %{url: url} ->
        send(parent, {:url, url})

        cond do
          String.contains?(url, "/issues/") -> {:ok, %{status: 200, body: []}}
          String.contains?(url, "/pulls?") -> {:ok, %{status: 200, body: []}}
        end
      end

      assert {:ok, %{count: 0}} =
               GithubCommentsPoller.poll([target],
                 boot_time: boot_time,
                 repo: repo,
                 request_fun: request_fun
               )

      expected_since =
        "since=" <> URI.encode_www_form(GithubKeys.boot_cutoff_iso8601(boot_time: boot_time))

      assert_receive {:url, url1}, 2000
      assert_receive {:url, url2}, 2000
      issue_url = Enum.find([url1, url2], &String.contains?(&1, "/comments?"))
      assert String.contains?(issue_url, expected_since)
    end

    test "firehose drops pre-boot events and passes post-boot events" do
      boot_time = 1_782_302_400
      repo = "owner/repo-#{System.unique_integer([:positive])}"

      pre_boot = %{
        "type" => "PushEvent",
        "actor" => %{"login" => "alice"},
        "repo" => %{"name" => "owner/repo"},
        "created_at" => "2020-01-01T00:00:00Z",
        "payload" => %{
          "ref" => "refs/heads/main",
          "head" => "pre-#{System.unique_integer([:positive])}",
          "commits" => []
        }
      }

      post_boot = %{
        "type" => "PushEvent",
        "actor" => %{"login" => "bob"},
        "repo" => %{"name" => "owner/repo"},
        "created_at" => DateTime.to_iso8601(DateTime.from_unix!(boot_time + 300)),
        "payload" => %{
          "ref" => "refs/heads/main",
          "head" => "post-#{System.unique_integer([:positive])}",
          "commits" => []
        }
      }

      stub = fn _req ->
        {:ok,
         %{
           status: 200,
           headers: [{"ETag", ~s("e-#{System.unique_integer([:positive])}")}],
           body: [pre_boot, post_boot]
         }}
      end

      :ok = Exchange.subscribe("system.main.branch.push")

      assert {:ok, %{count: 1}} =
               GithubFirehose.poll(request_fun: stub, boot_time: boot_time, repo: repo)

      assert_receive {:event, %{topic: "system.main.branch.push"}}, 2000
      refute_received {:event, _}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp issue_comment(id, login, body, iso_ts) do
    %{
      "id" => id,
      "body" => body,
      "user" => %{"login" => login},
      "created_at" => iso_ts,
      "updated_at" => iso_ts
    }
  end

  defp ensure_codeowners!(contents) do
    case Process.whereis(CodeOwners) do
      pid when is_pid(pid) ->
        previous_allowlist = CodeOwners.snapshot(pid)
        :sys.replace_state(pid, &%{&1 | allowlist: MapSet.new(["its-everdred"])})

        %{pid: pid, path: nil, owned?: false, previous_allowlist: previous_allowlist}

      nil ->
        path =
          Aiur.TestSupport.tmp_root!("aiur-codeowners")

        File.write!(path, contents)

        {:ok, pid} = CodeOwners.start_link(path: path, refresh_seconds: 3600)

        %{pid: pid, path: path, owned?: true}
    end
  end

  defp stop_codeowners(%{pid: pid, owned?: false, previous_allowlist: previous_allowlist}) do
    if Process.alive?(pid) do
      :sys.replace_state(pid, &%{&1 | allowlist: MapSet.new(previous_allowlist)})
    end
  end

  defp stop_codeowners(%{pid: pid, path: path, owned?: true}) do
    Aiur.TestSupport.safe_stop(pid)
    File.rm(path)
  end

  defp review_threads_response(nodes) do
    {:ok,
     %{
       status: 200,
       body: %{
         "data" => %{
           "repository" => %{
             "pullRequest" => %{
               "reviewThreads" => %{
                 "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil},
                 "nodes" => nodes
               }
             }
           }
         }
       }
     }}
  end

  defp review_thread_comment(id, login, body) do
    %{
      "databaseId" => id,
      "body" => body,
      "createdAt" => "2026-06-24T10:00:00Z",
      "updatedAt" => "2026-06-24T10:00:00Z",
      "url" => "https://github.test/discussion_r#{id}",
      "author" => %{"login" => login}
    }
  end
end
