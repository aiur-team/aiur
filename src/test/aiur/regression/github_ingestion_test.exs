defmodule Aiur.Regression.GithubIngestionTest do
  use Aiur.TestSupport

  alias Aiur.Events.{
    Exchange,
    GithubCommentsPoller,
    GithubFirehose,
    GithubKeys,
    LsRemoteTicker,
    Publisher
  }

  alias Aiur.GitHub.{CodeOwners, Connectivity}

  setup do
    # Isolate the per-issue/alert log to a tmp dir: this file exercises
    # `src/lib/aiur/events`, whose publishes record IssueLog/alert markers.
    tmp_dir =
      Path.join(System.tmp_dir!(), "aiur_github_ingestion_test_#{System.unique_integer([:positive])}")

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

      # Tolerant rm_rf: matches the `File.rm_rf/1` teardown convention in
      # `Aiur.TestSupport`; the dir is unique per test so a rare leftover is
      # harmless.
      File.rm_rf(tmp_dir)
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

  describe "Agent Workpad comment filtering" do
    test "issue comments starting '## Agent Workpad' are not published" do
      target = Integer.to_string(System.unique_integer([:positive]))
      repo = "owner/repo-#{System.unique_integer([:positive])}"
      id = System.unique_integer([:positive])

      request_fun = fn %{url: url} ->
        cond do
          String.contains?(url, "/issues/#{target}/comments?") ->
            {:ok,
             %{
               status: 200,
               body: [issue_comment(id, "alice", "  ## Agent Workpad\nstate", "2026-07-01T12:00:00Z")]
             }}

          String.contains?(url, "/pulls?") ->
            {:ok, %{status: 200, body: []}}
        end
      end

      # CommentFilter.agent_workpad?/1 trims leading whitespace before the
      # "## Agent Workpad" prefix check.
      assert {:ok, %{count: 0}} =
               GithubCommentsPoller.poll([target],
                 since: "2026-07-01T00:00:00Z",
                 repo: repo,
                 request_fun: request_fun
               )
    end

    test "PR-conversation workpad comments filtered; sibling real comment published" do
      target = Integer.to_string(System.unique_integer([:positive]))
      repo = "owner/repo-#{System.unique_integer([:positive])}"
      id_pad = System.unique_integer([:positive])
      id_real = System.unique_integer([:positive])

      request_fun = fn %{url: url} ->
        cond do
          # Match the target URL FIRST — both this and the PR-number URL
          # contain "/issues/".
          String.contains?(url, "/issues/#{target}/comments?") ->
            {:ok, %{status: 200, body: []}}

          String.contains?(url, "/issues/91/comments?") ->
            {:ok,
             %{
               status: 200,
               body: [
                 issue_comment(id_pad, "alice", "## Agent Workpad\nstate", "2026-07-01T12:00:00Z"),
                 issue_comment(id_real, "alice", "please fix the retry loop", "2026-07-01T12:01:00Z")
               ]
             }}

          String.contains?(url, "/graphql") ->
            empty_review_threads_response()
        end
      end

      assert {:ok, %{count: 1}} =
               GithubCommentsPoller.poll([target],
                 since: "2026-07-01T00:00:00Z",
                 repo: repo,
                 request_fun: request_fun,
                 open_pull_requests_by_target: %{target => %{"number" => 91}}
               )
    end
  end

  describe "per-target poll isolation and since cursor" do
    test "one erroring target does not stall the others" do
      a = Integer.to_string(System.unique_integer([:positive]))
      b = Integer.to_string(System.unique_integer([:positive]))
      repo = "owner/repo-#{System.unique_integer([:positive])}"
      id = System.unique_integer([:positive])

      request_fun = fn %{url: url} ->
        cond do
          String.contains?(url, "/issues/#{a}/comments?") ->
            {:error, %{reason: :econnrefused}}

          String.contains?(url, "/issues/#{b}/comments?") ->
            {:ok, %{status: 200, body: [issue_comment(id, "alice", "b moves", "2026-07-01T12:00:00Z")]}}

          String.contains?(url, "/pulls?") ->
            {:ok, %{status: 200, body: []}}
        end
      end

      assert {:ok, %{count: 1, since: since_map, errors: errors}} =
               GithubCommentsPoller.poll([a, b],
                 since: "2026-07-01T00:00:00Z",
                 repo: repo,
                 request_fun: request_fun,
                 max_concurrency: 2
               )

      # Erroring target freezes its cursor; the sibling advances.
      assert since_map[a] == "2026-07-01T00:00:00Z"
      assert since_map[b] != "2026-07-01T00:00:00Z"
      assert [{^a, {:issue_comments, _}}] = errors
    end

    test "a hung target is killed at the task timeout; siblings publish" do
      a = Integer.to_string(System.unique_integer([:positive]))
      b = Integer.to_string(System.unique_integer([:positive]))
      repo = "owner/repo-#{System.unique_integer([:positive])}"
      id = System.unique_integer([:positive])

      request_fun = fn %{url: url} ->
        cond do
          String.contains?(url, "/issues/#{a}/comments?") ->
            receive do
              :never -> :ok
            end

          String.contains?(url, "/issues/#{b}/comments?") ->
            {:ok, %{status: 200, body: [issue_comment(id, "alice", "b moves", "2026-07-01T12:00:00Z")]}}

          String.contains?(url, "/pulls?") ->
            {:ok, %{status: 200, body: []}}
        end
      end

      assert {:ok, %{count: 1, since: since_map, errors: [{^a, {:target, {:exit, :timeout}}}]}} =
               GithubCommentsPoller.poll([a, b],
                 since: "2026-07-01T00:00:00Z",
                 repo: repo,
                 request_fun: request_fun,
                 max_concurrency: 2,
                 timeout: 500
               )

      assert since_map[a] == "2026-07-01T00:00:00Z"
    end

    test "since advances to newest updated_at minus 1s on a clean poll" do
      target = Integer.to_string(System.unique_integer([:positive]))
      repo = "owner/repo-#{System.unique_integer([:positive])}"
      id = System.unique_integer([:positive])

      request_fun = fn %{url: url} ->
        cond do
          String.contains?(url, "/issues/#{target}/comments?") ->
            {:ok, %{status: 200, body: [issue_comment(id, "alice", "newest", "2026-07-01T12:00:00Z")]}}

          String.contains?(url, "/pulls?") ->
            {:ok, %{status: 200, body: []}}
        end
      end

      assert {:ok, %{since: since_map}} =
               GithubCommentsPoller.poll([target],
                 since: "2026-07-01T00:00:00Z",
                 repo: repo,
                 request_fun: request_fun
               )

      assert since_map[target] == "2026-07-01T11:59:59Z"
    end
  end

  describe "connectivity backoff wiring (#655)" do
    test "dns failures actually back off exponentially" do
      dns = {:error, {:git_ls_remote_failed, 128, "fatal: Could not resolve host: github.com"}}
      {pid, _repo} = start_ticker!([dns, dns])

      send(pid, :tick)
      assert :sys.get_state(pid).next_delay_ms == 1_000

      send(pid, :tick)
      assert :sys.get_state(pid).next_delay_ms == 2_000
    end

    test "auth failure escalates to the max backoff" do
      auth = {:error, {:git_ls_remote_failed, 128, "fatal: Authentication failed"}}
      {pid, _repo} = start_ticker!([auth])

      send(pid, :tick)
      assert :sys.get_state(pid).next_delay_ms == Connectivity.max_backoff_ms()
    end

    test "success resets the delay and clears the streak" do
      dns = {:error, {:git_ls_remote_failed, 128, "fatal: Could not resolve host: github.com"}}
      {pid, _repo} = start_ticker!([dns, {:ok, %{}}])

      send(pid, :tick)
      assert :sys.get_state(pid).next_delay_ms == 1_000

      send(pid, :tick)
      state = :sys.get_state(pid)
      assert state.next_delay_ms == 60_000
      assert state.connectivity == %{}
    end

    test "sustained dns streak alerts exactly once at threshold 3" do
      dns = {:error, {:git_ls_remote_failed, 128, "fatal: Could not resolve host: github.com"}}
      :ok = Exchange.subscribe("system.github.connectivity_lost")
      {pid, _repo} = start_ticker!([dns])

      send(pid, :tick)
      :sys.get_state(pid)
      send(pid, :tick)
      :sys.get_state(pid)
      refute_received {:event, %{topic: "system.github.connectivity_lost"}}

      send(pid, :tick)
      :sys.get_state(pid)
      assert_receive {:event, %{topic: "system.github.connectivity_lost"}}, 2000

      # Past the threshold stays silent until a success re-arms.
      send(pid, :tick)
      :sys.get_state(pid)
      refute_received {:event, %{topic: "system.github.connectivity_lost"}}
    end
  end

  describe "legacy and readable refs/heads/aiur routing" do
    test "ref_to_topic classification table" do
      assert GithubKeys.ref_to_topic("refs/heads/aiur/123") ==
               {:ticket, "123", "ticket.123.branch.push"}

      assert GithubKeys.ref_to_topic("refs/heads/aiur/99-pr") == {:ticket, "99", "ticket.99.branch.push"}
      assert GithubKeys.ref_to_topic("refs/heads/aiur/99/sub") == nil
      assert GithubKeys.ref_to_topic("refs/heads/aiur/abc") == nil
      assert GithubKeys.ref_to_topic("refs/heads/main") == {:system, "system.main.branch.push"}
      assert GithubKeys.ref_to_topic(nil) == nil
      assert GithubKeys.ref_to_topic(123) == nil
    end

    test "ticker publishes only canonical ticket refs after bootstrap" do
      {pid, repo} =
        start_ticker!([
          {:ok,
           %{
             "refs/heads/aiur/77" => "sha1",
             "refs/heads/aiur/77--pr" => "shaX",
             "refs/heads/main" => "m1"
           }},
          {:ok,
           %{
             "refs/heads/aiur/77" => "sha2",
             "refs/heads/aiur/77--pr" => "shaY",
             "refs/heads/aiur/88" => "new1",
             "refs/heads/main" => "m1"
           }}
        ])

      # Bootstrap tick records refs without publishing.
      send(pid, :tick)
      :sys.get_state(pid)
      refute_received {:published, _, _, _}

      # Second tick: only valid ticket refs publish; malformed and unchanged refs do not.
      send(pid, :tick)
      :sys.get_state(pid)

      assert_receive {:published, "ticket.77.branch.push", payload_77, opts_77}, 2000
      assert payload_77 == %{source: :system, ref: "refs/heads/aiur/77", sha: "sha2", actor: nil, commits: [], repo: repo}
      assert opts_77[:issue_number] == "77"

      assert_receive {:published, "ticket.88.branch.push", _, _}, 2000
      refute_received {:published, _, _, _}
    end

    test "error ticks never fake a bootstrap baseline" do
      dns = {:error, {:git_ls_remote_failed, 128, "fatal: Could not resolve host: github.com"}}

      {pid, _repo} =
        start_ticker!([
          dns,
          {:ok, %{"refs/heads/aiur/55" => "s1"}},
          {:ok, %{"refs/heads/aiur/55" => "s2"}}
        ])

      send(pid, :tick)
      assert :sys.get_state(pid).bootstrapped? == false

      # First SUCCESS is the baseline — no phantom-push storm.
      send(pid, :tick)
      assert :sys.get_state(pid).bootstrapped? == true
      refute_received {:published, _, _, _}

      send(pid, :tick)
      :sys.get_state(pid)
      assert_receive {:published, "ticket.55.branch.push", %{sha: "s2"}, _}, 2000
    end
  end

  describe "trusted-account gating (CODEOWNERS authority)" do
    test "comments stamp author_trusted?: false when no allowlist matches" do
      target = Integer.to_string(System.unique_integer([:positive]))
      repo = "owner/repo-#{System.unique_integer([:positive])}"
      id = System.unique_integer([:positive])

      request_fun = fn %{url: url} ->
        cond do
          String.contains?(url, "/issues/#{target}/comments?") ->
            {:ok, %{status: 200, body: [issue_comment(id, "stranger", "drive-by", "2026-07-01T12:00:00Z")]}}

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

      assert_receive {:event, event}, 2000
      assert event.author_trusted? == false
    end

    test "comments from a CODEOWNERS-listed author stamp author_trusted?: true" do
      target = Integer.to_string(System.unique_integer([:positive]))
      repo = "owner/repo-#{System.unique_integer([:positive])}"
      id = System.unique_integer([:positive])
      codeowners = ensure_codeowners!("* @its-everdred\n")
      on_exit(fn -> stop_codeowners(codeowners) end)

      request_fun = fn %{url: url} ->
        cond do
          String.contains?(url, "/issues/#{target}/comments?") ->
            {:ok,
             %{
               status: 200,
               body: [issue_comment(id, "its-everdred", "owner comment", "2026-07-01T12:00:00Z")]
             }}

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

      assert_receive {:event, event}, 2000
      assert event.author_trusted? == true
    end

    test "comment publishes bypass the contamination filter (deactivated-ticket wake)" do
      target = Integer.to_string(System.unique_integer([:positive]))
      repo = "owner/repo-#{System.unique_integer([:positive])}"
      id = System.unique_integer([:positive])

      # Ticket is absent from the tracked set, but an inbound human comment must
      # still reach the orchestrator to reactivate it (FI-EVT-010).
      Publisher.set_tracked_fn(fn _ -> false end)

      request_fun = fn %{url: url} ->
        cond do
          String.contains?(url, "/issues/#{target}/comments?") ->
            {:ok,
             %{
               status: 200,
               body: [issue_comment(id, "its-everdred", "reactivate me", "2026-07-01T12:00:00Z")]
             }}

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

  defp start_ticker!(responses) do
    test_pid = self()
    repo = "owner/repo-#{System.unique_integer([:positive])}"
    {:ok, agent} = Agent.start_link(fn -> responses end)

    ls_remote_fun = fn _remote, _refs ->
      Agent.get_and_update(agent, fn [h | t] -> {h, t ++ [h]} end)
    end

    publisher = fn topic, payload, opts ->
      send(test_pid, {:published, topic, payload, opts})
      :ok
    end

    {:ok, pid} =
      LsRemoteTicker.start_link(
        name: :"ticker_#{System.unique_integer([:positive])}",
        start_paused?: true,
        interval_ms: 60_000,
        repo: repo,
        ls_remote_fun: ls_remote_fun,
        publisher: publisher
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)
    {pid, repo}
  end

  defp ensure_codeowners!(contents) do
    case Process.whereis(CodeOwners) do
      pid when is_pid(pid) ->
        previous_allowlist = CodeOwners.snapshot(pid)
        :sys.replace_state(pid, &%{&1 | allowlist: MapSet.new(["its-everdred"])})

        %{pid: pid, path: nil, owned?: false, previous_allowlist: previous_allowlist}

      nil ->
        path =
          Path.join(System.tmp_dir!(), "aiur-codeowners-#{System.unique_integer([:positive])}")

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
    if Process.alive?(pid), do: GenServer.stop(pid)
    File.rm(path)
  end

  defp empty_review_threads_response, do: review_threads_response([])

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
