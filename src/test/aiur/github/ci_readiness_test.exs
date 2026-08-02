defmodule Aiur.GitHub.CiReadinessTest do
  use ExUnit.Case, async: true

  alias Aiur.GitHub.CiReadiness

  @workflow """
  name: CI
  on:
    pull_request:
      branches: [develop]
  jobs:
    test:
      name: ci / required
      runs-on: ubuntu-latest
      steps:
        - run: true
  """

  test "reports a repository without a pull request workflow" do
    readiness = CiReadiness.evaluate("develop", [{".github/workflows/push.yml", "on:\n  push:\n"}], ["ci / required"])

    refute readiness.ready?
    assert :no_pr_workflow in readiness.issues
  end

  test "reports a workflow with no required check" do
    readiness = CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", @workflow}], [])

    refute readiness.ready?
    assert :no_required_check in readiness.issues
  end

  test "reports required checks which no pull request workflow produces" do
    readiness = CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", @workflow}], ["ci / aggregate"])

    refute readiness.ready?
    assert {:required_check_not_produced, ["ci / aggregate"]} in readiness.issues
  end

  test "accepts a matching required check from a configured pull request workflow" do
    readiness = CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", @workflow}], ["ci / required"])

    assert readiness.ready?
    assert readiness.workflow_paths == [".github/workflows/ci.yml"]
    assert readiness.required_checks == ["ci / required"]
  end

  test "reports a missing configured base branch before inspecting workflows" do
    request_fun = fn %{url: url} ->
      assert url =~ "/branches/develop"
      {:ok, %{status: 404, body: %{}}}
    end

    assert {:ok, %{ready?: false, issues: [:base_branch_missing]}} =
             CiReadiness.inspect_repository(request_fun, "token", "owner", "repo", "develop")
  end

  test "fetches workflow content and required checks through the GitHub transport" do
    encoded = Base.encode64(@workflow)

    request_fun = fn %{url: url} ->
      cond do
        String.ends_with?(url, "/branches/develop") -> {:ok, %{status: 200, body: %{}}}
        url =~ "/contents/.github/workflows" -> {:ok, %{status: 200, body: [%{"type" => "file", "path" => ".github/workflows/ci.yml", "url" => "workflow-url"}]}}
        url == "workflow-url" -> {:ok, %{status: 200, body: %{"content" => encoded}}}
        url =~ "/protection" -> {:ok, %{status: 200, body: %{"required_status_checks" => %{"contexts" => ["ci / required"]}}}}
      end
    end

    assert {:ok, %{ready?: true, required_checks: ["ci / required"]}} =
             CiReadiness.inspect_repository(request_fun, "token", "owner", "repo", "develop")
  end
end
