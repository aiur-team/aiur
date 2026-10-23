defmodule Aiur.LandingWatch.RunnerQueueTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch.{Journal, RunnerQueue}

  @now_ms DateTime.to_unix(~U[2026-10-23 16:00:00Z], :millisecond)

  test "summarizes only queued pull request ci runs and reports the oldest wait" do
    runs = [
      run(1, 17, "head-17", "queued", "2026-10-23T15:30:00Z"),
      run(2, 18, "head-18", "queued", "2026-10-23T15:00:00Z"),
      run(3, 19, "head-19", "in_progress", "2026-10-23T14:00:00Z"),
      run(4, 20, "head-20", "queued", "2026-10-23T14:00:00Z") |> Map.put("event", "merge_group"),
      run(5, 21, "head-21", "queued", "2026-10-23T14:00:00Z") |> Map.put("name", "website")
    ]

    summary = RunnerQueue.summarize(runs, @now_ms)
    assert summary.total == 2
    assert summary.oldest_age_ms == 60 * 60_000
  end

  test "follows Actions pagination when counting queued PR runs" do
    parent = self()
    page_one = "https://api.github.com/repos/test-org/test-repo/actions/runs?event=pull_request&page=2&per_page=100&status=queued"

    assert {:ok, summary} =
             RunnerQueue.census(
               parse_repo_fun: fn -> {:ok, {"test-org", "test-repo"}} end,
               token: "test-token",
               base_url: "https://api.github.com",
               now_ms: @now_ms,
               request_fun: fn request ->
                 send(parent, {:page, request.url})

                 if String.contains?(request.url, "page=2") do
                   {:ok, %{status: 200, body: %{"workflow_runs" => [run(2, 18, "head-18", "queued", "2026-10-23T15:00:00Z")]}, headers: []}}
                 else
                   {:ok, %{status: 200, body: %{"workflow_runs" => [run(1, 17, "head-17", "queued", "2026-10-23T15:30:00Z")]}, headers: [{"link", "<#{page_one}>; rel=\"next\""}]}}
                 end
               end
             )

    assert summary.total == 2
    assert_received {:page, first_url}
    assert first_url =~ "status=queued"
    assert_received {:page, ^page_one}
  end

  test "cancels only unapproved exact-head PR runs and restores them after queue drains" do
    path = journal_path()
    parent = self()
    run = run(99, 17, "head-17", "queued", "2026-10-23T15:30:00Z")
    observation = observation(17, "head-17", "REVIEW_REQUIRED")

    common = [
      parse_repo_fun: fn -> {:ok, {"test-org", "test-repo"}} end,
      token: "test-token",
      base_url: "https://api.github.com",
      journal_path: path,
      now_ms: @now_ms,
      request_fun: fn _ -> {:ok, %{status: 200, body: %{"workflow_runs" => [run]}}} end,
      observe_all_fun: fn _ -> {:ok, [observation]} end,
      deferable_fun: fn 17, "head-17", _ -> :ok end,
      cancel_fun: fn 99, _ ->
        send(parent, :cancelled)
        :ok
      end,
      alert_emitter: fn topic, attrs ->
        send(parent, {:alert, topic, attrs})
        :ok
      end,
      threshold: 1,
      drain_threshold: 0
    ]

    assert :ok = RunnerQueue.reconcile(common)
    assert_received :cancelled
    assert {:ok, [%{"id" => 99, "pr" => 17, "head" => "head-17"}]} = Journal.deferred_runner_runs(journal_path: path)
    assert_received {:alert, "system.ci.runner_queue", attrs}
    assert attrs[:exchange_payload]["queued"] == 1
    assert attrs[:exchange_payload]["deferred"] == 1

    request = fn %{method: :get} -> {:ok, %{status: 200, body: %{"workflow_runs" => []}}} end

    assert :ok =
             RunnerQueue.reconcile(
               Keyword.merge(common,
                 request_fun: request,
                 rerun_fun: fn 99, _ ->
                   send(parent, :restored)
                   {:ok, %{}}
                 end
               )
             )

    assert_received :restored
    assert {:ok, []} = Journal.deferred_runner_runs(journal_path: path)
  end

  test "never cancels approved, auto-merge, merge-queued, or head-mismatched PRs" do
    path = journal_path()

    protected = [
      observation(17, "head-17", "APPROVED"),
      %{observation(18, "head-18", "REVIEW_REQUIRED") | auto_merge_request: %{"enabledAt" => "now"}},
      %{observation(19, "head-19", "REVIEW_REQUIRED") | merge_queue_entry: %{"id" => "queue-entry"}},
      observation(20, "new-head", "REVIEW_REQUIRED")
    ]

    runs = Enum.map(17..20, &run(&1, &1, "head-#{&1}", "queued", "2026-10-23T15:30:00Z"))

    assert :ok =
             RunnerQueue.reconcile(
               parse_repo_fun: fn -> {:ok, {"test-org", "test-repo"}} end,
               token: "test-token",
               journal_path: path,
               request_fun: fn _ -> {:ok, %{status: 200, body: %{"workflow_runs" => runs}}} end,
               observe_all_fun: fn _ -> {:ok, protected} end,
               alert_emitter: fn _, _ -> :ok end,
               threshold: 1,
               deferable_fun: fn _, _, _ -> flunk("protected PR must not reach final eligibility check") end,
               cancel_fun: fn _, _ -> flunk("protected PR workflow must not be cancelled") end
             )
  end

  test "restore drops a deferred run if the PR is now approved or its head changed" do
    path = journal_path()
    assert :ok = Journal.defer_runner_run(%{"id" => 88, "pr" => 17, "head" => "old-head", "deferred_at_ms" => @now_ms}, journal_path: path)
    run = run(89, 18, "head-18", "queued", "2026-10-23T15:30:00Z")

    assert :ok =
             RunnerQueue.reconcile(
               parse_repo_fun: fn -> {:ok, {"test-org", "test-repo"}} end,
               token: "test-token",
               journal_path: path,
               request_fun: fn _ -> {:ok, %{status: 200, body: %{"workflow_runs" => [run]}}} end,
               observe_all_fun: fn _ -> {:ok, [observation(17, "new-head", "APPROVED"), observation(18, "head-18", "REVIEW_REQUIRED")]} end,
               alert_emitter: fn _, _ -> :ok end,
               threshold: 10,
               drain_threshold: 1,
               rerun_fun: fn _, _ -> flunk("stale deferred run must not be rerun") end
             )

    assert {:ok, []} = Journal.deferred_runner_runs(journal_path: path)
  end

  defp observation(number, head, decision) do
    %{number: number, head: head, state: "OPEN", draft?: false, review_decision: decision, auto_merge_request: nil, merge_queue_entry: nil}
  end

  defp run(id, number, head, status, created_at) do
    %{"id" => id, "name" => "ci", "event" => "pull_request", "status" => status, "created_at" => created_at, "head_sha" => head, "pull_requests" => [%{"number" => number}]}
  end

  defp journal_path do
    Path.join(System.tmp_dir!(), "runner-queue-#{System.unique_integer([:positive])}.json")
  end
end
