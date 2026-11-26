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

  test "cancelled-only heads stay pending without rerunning after a poll or restart" do
    checks = [check("ci / required", "cancelled"), check("merge ruleset drift", "failure")]

    for _poll_or_restart <- 1..2 do
      assert %{decision: :pending, pending_reason: :ci_cancelled, failures: []} = poll(checks, request_fun: no_requests())
    end
  end

  test "a cancelled sibling does not hide a failed required check" do
    checks = [check("ci / required", "failure"), check("test", "cancelled")]

    assert %{decision: :failed, failures: failures} = poll(checks, request_fun: no_requests())
    assert Enum.map(failures, & &1.name) == ["ci / required"]
    refute Map.has_key?(poll(checks, request_fun: no_requests()), :pending_reason)
  end
end
