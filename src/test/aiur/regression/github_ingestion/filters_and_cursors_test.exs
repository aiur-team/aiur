defmodule Aiur.Regression.GithubIngestion.FiltersAndCursorsTest do
  use Aiur.TestSupport

  alias Aiur.Events.Exchange
  alias Aiur.Events.GithubCommentsPoller
  alias Aiur.Events.LsRemoteTicker
  alias Aiur.Events.Publisher

  alias Aiur.GitHub.Connectivity

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

          String.contains?(url, "/reviews") ->
            {:ok, %{status: 200, body: []}}

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

    on_exit(fn -> Aiur.TestSupport.safe_stop(pid) end)
    on_exit(fn -> Aiur.TestSupport.safe_stop(agent) end)
    {pid, repo}
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
end
