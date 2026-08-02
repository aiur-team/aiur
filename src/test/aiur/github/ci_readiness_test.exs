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

  test "accepts the unconfigured pull request trigger emitted by the scaffold" do
    assert CiReadiness.evaluate("main", [{".github/workflows/ci.yml", CiReadiness.scaffold()}], ["ci / required"]).ready?
  end

  test "does not treat a workflow excluded from the base branch as a PR workflow" do
    workflow = """
    on:
      pull_request:
        branches-ignore: [develop]
    jobs:
      test:
        name: ci / required
    """

    readiness = CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", workflow}], ["ci / required"])

    refute readiness.ready?
    assert :no_pr_workflow in readiness.issues
  end

  test "matches branch glob filters for the configured base branch" do
    workflow = String.replace(@workflow, "branches: [develop]", "branches: [release/**]")

    assert CiReadiness.evaluate("release/2026", [{".github/workflows/ci.yml", workflow}], ["ci / required"]).ready?
  end

  test "honors later negative branch patterns" do
    workflow = String.replace(@workflow, "branches: [develop]", "branches: [\"**\", \"!develop\"]")

    readiness = CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", workflow}], ["ci / required"])

    refute readiness.ready?
    assert :no_pr_workflow in readiness.issues
  end

  test "rejects conditional pull request workflows as universal gates" do
    workflow =
      String.replace(
        @workflow,
        "branches: [develop]",
        "types: [labeled]\n    paths: [docs/**]"
      )

    readiness = CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", workflow}], ["ci / required"])

    refute readiness.ready?
    assert :no_pr_workflow in readiness.issues
  end

  test "does not count a push-only job as a pull request check" do
    workflow = String.replace(@workflow, "runs-on: ubuntu-latest", "if: github.event_name == 'push'\n      runs-on: ubuntu-latest")

    readiness = CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", workflow}], ["ci / required"])

    refute readiness.ready?
    assert {:required_check_not_produced, ["ci / required"]} in readiness.issues
  end

  test "does not treat a condition with an extra gate as an unconditional PR check" do
    workflow =
      String.replace(
        @workflow,
        "runs-on: ubuntu-latest",
        "if: github.event_name == 'pull_request' && github.actor == 'maintainer'\n      runs-on: ubuntu-latest"
      )

    readiness = CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", workflow}], ["ci / required"])

    refute readiness.ready?
    assert {:required_check_not_produced, ["ci / required"]} in readiness.issues
  end

  test "recognizes an always condition wrapped in GitHub expression delimiters" do
    workflow = """
    on:
      pull_request:
        branches: [develop]
    jobs:
      test:
        name: ci / required
        if: ${{ always() }}
        runs-on: ubuntu-latest
    """

    assert CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", workflow}], ["ci / required"]).ready?
  end

  test "reports a missing configured base branch before inspecting workflows" do
    request_fun = fn %{url: url} ->
      assert url =~ "/branches/develop"
      {:ok, %{status: 404, body: %{}}}
    end

    assert {:ok, %{ready?: false, issues: [:base_branch_missing]}} =
             CiReadiness.inspect_repository(request_fun, "token", "owner", "repo", "develop")
  end

  test "encodes configured branch names as path and query components" do
    branch = "feature/#&gate"
    parent = self()

    request_fun = fn %{url: url} ->
      send(parent, {:readiness_url, url})

      cond do
        url =~ "/branches/feature%2F%23%26gate" -> {:ok, %{status: 200, body: %{}}}
        String.ends_with?(url, "/repos/owner/repo") -> {:ok, %{status: 200, body: %{"default_branch" => branch}}}
        url =~ "/contents/.github/workflows?ref=feature%2F%23%26gate" -> {:ok, %{status: 200, body: []}}
        url =~ "/actions/workflows?per_page=100" -> {:ok, %{status: 200, body: %{"workflows" => []}}}
        url =~ "/protection" -> {:ok, %{status: 404, body: %{}}}
        url =~ "/rulesets" -> {:ok, %{status: 200, body: []}}
        true -> flunk("unexpected URL: #{url}")
      end
    end

    assert {:ok, %{issues: [:no_pr_workflow, :no_required_check]}} =
             CiReadiness.inspect_repository(request_fun, "token", "owner", "repo", branch)

    assert_receive {:readiness_url, branch_url}
    assert branch_url =~ "/branches/feature%2F%23%26gate"

    assert_receive {:readiness_url, _repo_url}

    assert_receive {:readiness_url, workflow_url}
    assert workflow_url =~ "?ref=feature%2F%23%26gate"
  end

  test "fetches workflow content and required checks through the GitHub transport" do
    encoded = Base.encode64(@workflow)

    request_fun = fn %{url: url} ->
      cond do
        String.ends_with?(url, "/branches/develop") ->
          {:ok, %{status: 200, body: %{}}}

        String.ends_with?(url, "/repos/owner/repo") ->
          {:ok, %{status: 200, body: %{"default_branch" => "develop"}}}

        url =~ "/actions/workflows?per_page=100" ->
          {:ok, %{status: 200, body: %{"workflows" => [%{"path" => ".github/workflows/ci.yml", "state" => "active"}]}}}

        url =~ "/contents/.github/workflows" ->
          {:ok, %{status: 200, body: [%{"type" => "file", "path" => ".github/workflows/ci.yml", "url" => "workflow-url"}]}}

        url == "workflow-url?ref=develop" ->
          {:ok, %{status: 200, body: %{"content" => encoded}}}

        url =~ "/protection" ->
          {:ok, %{status: 200, body: %{"required_status_checks" => %{"contexts" => ["ci / required"]}}}}

        url =~ "/rulesets" ->
          {:ok, %{status: 200, body: []}}
      end
    end

    assert {:ok, %{ready?: true, required_checks: ["ci / required"]}} =
             CiReadiness.inspect_repository(request_fun, "token", "owner", "repo", "develop")
  end

  test "does not count a manually disabled workflow as a CI gate" do
    encoded = Base.encode64(@workflow)

    request_fun = fn %{url: url} ->
      cond do
        String.ends_with?(url, "/branches/develop") ->
          {:ok, %{status: 200, body: %{}}}

        String.ends_with?(url, "/repos/owner/repo") ->
          {:ok, %{status: 200, body: %{"default_branch" => "develop"}}}

        url =~ "/actions/workflows?per_page=100" ->
          {:ok, %{status: 200, body: %{"workflows" => [%{"path" => ".github/workflows/ci.yml", "state" => "disabled_manually"}]}}}

        url =~ "/contents/.github/workflows" ->
          {:ok, %{status: 200, body: [%{"type" => "file", "path" => ".github/workflows/ci.yml", "url" => "workflow-url"}]}}

        url == "workflow-url?ref=develop" ->
          {:ok, %{status: 200, body: %{"content" => encoded}}}

        url =~ "/protection" ->
          {:ok, %{status: 200, body: %{"required_status_checks" => %{"contexts" => ["ci / required"]}}}}

        url =~ "/rulesets" ->
          {:ok, %{status: 200, body: []}}
      end
    end

    assert {:ok, %{ready?: false, issues: issues}} =
             CiReadiness.inspect_repository(request_fun, "token", "owner", "repo", "develop")

    assert :no_pr_workflow in issues
  end

  test "combines branch protection and applicable ruleset checks" do
    encoded = Base.encode64(@workflow)

    request_fun = fn %{url: url} ->
      cond do
        String.ends_with?(url, "/branches/develop") ->
          {:ok, %{status: 200, body: %{}}}

        String.ends_with?(url, "/repos/owner/repo") ->
          {:ok, %{status: 200, body: %{"default_branch" => "develop"}}}

        url =~ "/actions/workflows?per_page=100" ->
          {:ok, %{status: 200, body: %{"workflows" => [%{"path" => ".github/workflows/ci.yml", "state" => "active"}]}}}

        url =~ "/contents/.github/workflows" ->
          {:ok, %{status: 200, body: [%{"type" => "file", "path" => ".github/workflows/ci.yml", "url" => "workflow-url"}]}}

        url == "workflow-url?ref=develop" ->
          {:ok, %{status: 200, body: %{"content" => encoded}}}

        url =~ "/protection" ->
          {:ok, %{status: 200, body: %{"required_status_checks" => %{"checks" => [%{"context" => "ci / required"}]}}}}

        String.ends_with?(url, "/rulesets?includes_parents=true&per_page=100") ->
          {:ok,
           %{
             status: 200,
             body: [%{"id" => 12}],
             headers: %{"link" => "<https://api.github.com/repos/owner/repo/rulesets?page=2>; rel=\"next\""}
           }}

        String.ends_with?(url, "/rulesets?page=2") ->
          {:ok, %{status: 200, body: [%{"id" => 15}]}}

        url =~ "/rulesets/12" ->
          {:ok,
           %{
             status: 200,
             body: %{
               "enforcement" => "active",
               "conditions" => %{"ref_name" => %{"include" => ["~DEFAULT_BRANCH"]}},
               "rules" => [%{"type" => "required_status_checks", "parameters" => %{"required_status_checks" => [%{"context" => "ci / aggregate"}]}}]
             }
           }}

        url =~ "/rulesets/15" ->
          {:ok,
           %{
             status: 200,
             body: %{
               "enforcement" => "active",
               "conditions" => %{"ref_name" => %{"include" => ["~ALL"]}},
               "rules" => [%{"type" => "required_status_checks", "parameters" => %{"required_status_checks" => [%{"context" => "ci / page two"}]}}]
             }
           }}
      end
    end

    assert {:ok,
            %{
              ready?: false,
              required_checks: ["ci / aggregate", "ci / page two", "ci / required"],
              issues: [{:required_check_not_produced, ["ci / aggregate", "ci / page two"]}]
            }} =
             CiReadiness.inspect_repository(request_fun, "token", "owner", "repo", "develop")
  end

  test "ignores rulesets which do not apply to the configured base branch" do
    encoded = Base.encode64(@workflow)

    request_fun = fn %{url: url} ->
      cond do
        String.ends_with?(url, "/branches/develop") ->
          {:ok, %{status: 200, body: %{}}}

        String.ends_with?(url, "/repos/owner/repo") ->
          {:ok, %{status: 200, body: %{"default_branch" => "develop"}}}

        url =~ "/actions/workflows?per_page=100" ->
          {:ok, %{status: 200, body: %{"workflows" => [%{"path" => ".github/workflows/ci.yml", "state" => "active"}]}}}

        url =~ "/contents/.github/workflows" ->
          {:ok, %{status: 200, body: [%{"type" => "file", "path" => ".github/workflows/ci.yml", "url" => "workflow-url"}]}}

        url == "workflow-url?ref=develop" ->
          {:ok, %{status: 200, body: %{"content" => encoded}}}

        url =~ "/protection" ->
          {:ok, %{status: 404, body: %{}}}

        url =~ "/rulesets?" ->
          {:ok, %{status: 200, body: [%{"id" => 13}]}}

        url =~ "/rulesets/13" ->
          {:ok,
           %{
             status: 200,
             body: %{
               "enforcement" => "active",
               "conditions" => %{"ref_name" => %{"include" => ["refs/heads/release/**"]}},
               "rules" => [%{"type" => "required_status_checks", "parameters" => %{"required_status_checks" => [%{"context" => "ci / aggregate"}]}}]
             }
           }}
      end
    end

    assert {:ok, %{ready?: false, issues: [:no_required_check]}} =
             CiReadiness.inspect_repository(request_fun, "token", "owner", "repo", "develop")
  end

  test "ignores disabled rulesets" do
    encoded = Base.encode64(@workflow)

    request_fun = fn %{url: url} ->
      cond do
        String.ends_with?(url, "/branches/develop") ->
          {:ok, %{status: 200, body: %{}}}

        String.ends_with?(url, "/repos/owner/repo") ->
          {:ok, %{status: 200, body: %{"default_branch" => "develop"}}}

        url =~ "/actions/workflows?per_page=100" ->
          {:ok, %{status: 200, body: %{"workflows" => [%{"path" => ".github/workflows/ci.yml", "state" => "active"}]}}}

        url =~ "/contents/.github/workflows" ->
          {:ok, %{status: 200, body: [%{"type" => "file", "path" => ".github/workflows/ci.yml", "url" => "workflow-url"}]}}

        url == "workflow-url?ref=develop" ->
          {:ok, %{status: 200, body: %{"content" => encoded}}}

        url =~ "/protection" ->
          {:ok, %{status: 404, body: %{}}}

        url =~ "/rulesets?" ->
          {:ok, %{status: 200, body: [%{"id" => 14}]}}

        url =~ "/rulesets/14" ->
          {:ok,
           %{
             status: 200,
             body: %{
               "enforcement" => "disabled",
               "conditions" => %{"ref_name" => %{"include" => ["~ALL"]}},
               "rules" => [%{"type" => "required_status_checks", "parameters" => %{"required_status_checks" => [%{"context" => "ci / required"}]}}]
             }
           }}
      end
    end

    assert {:ok, %{ready?: false, issues: [:no_required_check]}} =
             CiReadiness.inspect_repository(request_fun, "token", "owner", "repo", "develop")
  end
end
