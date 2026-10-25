defmodule Aiur.Regression.GithubIngestion.RoutingAndTrustTest do
  use Aiur.TestSupport

  alias Aiur.Events.Exchange
  alias Aiur.Events.GithubCommentsPoller
  alias Aiur.Events.GithubKeys
  alias Aiur.Events.LsRemoteTicker
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
      assert payload_77 == %{source: :system, ref: "refs/heads/aiur/77", sha: "sha2", previous_sha: "sha1", actor: nil, commits: [], repo: repo}
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

    on_exit(fn -> Aiur.TestSupport.safe_stop(pid) end)
    on_exit(fn -> Aiur.TestSupport.safe_stop(agent) end)
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
end
