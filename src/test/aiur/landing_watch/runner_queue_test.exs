defmodule Aiur.LandingWatch.RunnerQueueTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch.RunnerQueue

  @now_ms DateTime.to_unix(~U[2026-10-23 16:00:00Z], :millisecond)

  test "reports exact-head queue attribution and emits the runner queue event" do
    parent = self()
    observations = [observation(17, "head-17", true), observation(18, "head-18", false)]

    runs = [
      run(1, 17, "head-17", "2026-10-23T15:30:00Z"),
      run(2, 18, "head-18", "2026-10-23T15:20:00Z"),
      run(3, 19, "head-19", "2026-10-23T15:00:00Z"),
      run(4, 20, "head-20", "2026-10-23T14:00:00Z") |> Map.put("name", "website"),
      run(5, 21, "head-21", "2026-10-23T14:00:00Z") |> Map.put("event", "merge_group")
    ]

    assert :ok =
             RunnerQueue.report(observations,
               parse_repo_fun: fn -> {:ok, {"test-org", "test-repo"}} end,
               token: "test-token",
               now_ms: @now_ms,
               request_fun: fn request ->
                 send(parent, {:request, request})
                 {:ok, %{status: 200, body: %{"workflow_runs" => runs}, headers: []}}
               end,
               alert_emitter: fn topic, attrs ->
                 send(parent, {:event, topic, attrs})
                 :ok
               end
             )

    assert_received {:request, %{caller: "landing_watch_runner_queue", url: url}}
    assert url =~ "event=pull_request"
    assert url =~ "status=queued"

    assert_received {:event, "system.ci.runner_queue", attrs}

    assert attrs[:exchange_payload] == %{
             "queued" => 3,
             "approved_queued" => 1,
             "unapproved_queued" => 1,
             "unattributed_queued" => 1,
             "deferred" => 0,
             "oldest_age_ms" => 60 * 60_000,
             "oldest_approved_age_ms" => 30 * 60_000
           }
  end

  defp observation(number, head, approved?) do
    review = if approved?, do: "APPROVED", else: "REVIEW_REQUIRED"
    reviews = if approved?, do: %{"nodes" => [%{"commit" => %{"oid" => head}}]}, else: %{"nodes" => []}

    %{number: number, head: head, raw: %{"headRefOid" => head, "reviewDecision" => review, "reviews" => reviews}}
  end

  defp run(id, number, head, created_at) do
    %{
      "id" => id,
      "name" => "ci",
      "status" => "queued",
      "event" => "pull_request",
      "head_sha" => head,
      "pull_requests" => [%{"number" => number}],
      "created_at" => created_at
    }
  end
end
