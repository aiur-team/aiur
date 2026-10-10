defmodule Aiur.Events.GithubCIPollerRequiredVerdictTest do
  use ExUnit.Case, async: true

  alias Aiur.Events.GithubCIPoller

  @required [%{name: "ci / required", app_id: 15_368}]
  @pr %{"number" => 71, "head" => %{"ref" => "aiur/42", "sha" => "head-1", "repo" => %{"full_name" => "owner/repo"}}, "base" => %{"ref" => "main"}, "draft" => false}

  defp check(name, conclusion), do: %{"name" => name, "status" => "completed", "conclusion" => conclusion, "app" => %{"id" => 15_368}}

  defp poll(check_runs, opts) do
    batch = %{"42" => %{pull_request: @pr, check_runs: check_runs, commit_status: %{"statuses" => []}}}
    opts = Keyword.merge([ci_batch: batch, required_check_fetcher: fn _ -> {:ok, @required} end, repo: "owner/repo", token: "t"], opts)
    assert {:ok, %{results: [result]}} = GithubCIPoller.poll(["42"], opts)
    result
  end

  defp no_requests, do: fn request -> flunk("unexpected GitHub request: #{inspect(request)}") end

  test "a failing non-required check does not fail CI when the required checks passed" do
    checks = [check("ci / required", "success"), check("merge ruleset drift", "failure")]

    assert %{decision: :passed, failures: []} = poll(checks, request_fun: no_requests())
  end

  test "a failing required check still fails CI and reports every failure" do
    checks = [check("ci / required", "failure"), check("test", "failure")]

    assert %{decision: :failed, failures: failures} = poll(checks, request_fun: no_requests())
    assert Enum.map(failures, & &1.name) == ["ci / required", "test"]
  end

  test "without a required-check list every failure still decides" do
    checks = [check("ci / required", "success"), check("merge ruleset drift", "failure")]

    assert %{decision: :failed} = poll(checks, required_check_fetcher: fn _ -> {:ok, []} end, request_fun: no_requests())
  end

  test "a cancelled-only head re-runs the latest cancelled workflow run instead of reporting a failure" do
    test_pid = self()

    request_fun = fn
      %{method: :get, url: url} ->
        assert url =~ "/repos/owner/repo/actions/runs?head_sha=head-1"

        runs = [
          %{"id" => 1, "workflow_id" => 7, "conclusion" => "cancelled", "run_started_at" => "2026-10-10T15:00:00Z"},
          %{"id" => 2, "workflow_id" => 7, "conclusion" => "cancelled", "run_started_at" => "2026-10-10T17:00:00Z"},
          # A cancelled run superseded by a newer run of the same workflow is left alone.
          %{"id" => 3, "workflow_id" => 8, "conclusion" => "cancelled", "run_started_at" => "2026-10-10T15:00:00Z"},
          %{"id" => 4, "workflow_id" => 8, "conclusion" => "success", "run_started_at" => "2026-10-10T17:00:00Z"}
        ]

        {:ok, %{status: 200, body: %{"workflow_runs" => runs}}}

      %{method: :post, url: url} ->
        send(test_pid, {:rerun, url})
        {:ok, %{status: 201, body: %{}}}
    end

    checks = [check("ci / required", "cancelled"), check("merge ruleset drift", "failure")]

    assert %{decision: :pending, pending_reason: :ci_cancelled, failures: []} = poll(checks, request_fun: request_fun)
    assert_receive {:rerun, url}, 1000
    assert url =~ "/repos/owner/repo/actions/runs/2/rerun"
    refute_received {:rerun, _other}
  end

  test "a cancelled run beside a failed required check is not re-run" do
    checks = [check("ci / required", "failure"), check("test", "cancelled")]

    assert %{decision: :pending, pending_reason: :check_runs_incomplete} = poll(checks, request_fun: no_requests())
  end
end
