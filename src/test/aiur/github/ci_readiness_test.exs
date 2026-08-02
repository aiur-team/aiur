defmodule Aiur.GitHub.CiReadinessTest do
  use ExUnit.Case, async: false

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

  test "rejects a required check pinned to a different integration" do
    readiness =
      CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", @workflow}], [
        %{"context" => "ci / required", "app_id" => 42}
      ])

    refute readiness.ready?
    assert readiness.required_check_identities == [%{name: "ci / required", app_id: 42}]
    assert {:required_check_integration_not_produced, ["ci / required (app_id: 42)"]} in readiness.issues
  end

  test "accepts a required check pinned to GitHub Actions" do
    readiness =
      CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", @workflow}], [
        %{"context" => "ci / required", "app_id" => 15_368}
      ])

    assert readiness.ready?
  end

  test "uses an operator assessment only for its exact repository, base, and config fingerprint" do
    path = Path.join(System.tmp_dir!(), "aiur-ci-readiness-#{System.unique_integer([:positive])}.json")
    readiness = CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", @workflow}], ["ci / required"])
    opts = [repo: "owner/repo", base_branch: "develop", config_fingerprint: "config-a", path: path]

    on_exit(fn ->
      File.rm(path)
      CiReadiness.clear_cached_result()
    end)

    assert :ok = CiReadiness.persist_assessment(readiness, opts)
    assert :ok = CiReadiness.clear_cached_result()
    assert CiReadiness.cached_result(opts) == readiness
    assert CiReadiness.cached_result(Keyword.put(opts, :repo, "owner/other")) == :unavailable
    assert CiReadiness.cached_result(Keyword.put(opts, :base_branch, "main")) == :unavailable
    assert CiReadiness.cached_result(Keyword.put(opts, :config_fingerprint, "config-b")) == :unavailable
  end

  test "dispatch consumes a persisted operator assessment without elevated daemon access" do
    path = Path.join(System.tmp_dir!(), "aiur-ci-readiness-#{System.unique_integer([:positive])}.json")
    readiness = CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", @workflow}], ["ci / required"])
    opts = [repo: "owner/repo", base_branch: "develop", config_fingerprint: "config-a", path: path]
    original_token = System.get_env(CiReadiness.operator_token_env())

    on_exit(fn ->
      File.rm(path)
      CiReadiness.clear_cached_result()

      if original_token do
        System.put_env(CiReadiness.operator_token_env(), original_token)
      else
        System.delete_env(CiReadiness.operator_token_env())
      end
    end)

    assert :ok = CiReadiness.persist_assessment(readiness, opts)
    assert :ok = CiReadiness.clear_cached_result()
    System.delete_env(CiReadiness.operator_token_env())

    assert {:ok, ^readiness} =
             CiReadiness.dispatch_check(Keyword.put(opts, :request_fun, fn _request -> flunk("unexpected daemon request") end))
  end

  test "expires an unchanged-config assessment and detects a removed pull request gate" do
    path = Path.join(System.tmp_dir!(), "aiur-ci-readiness-#{System.unique_integer([:positive])}.json")
    now = DateTime.utc_now()
    readiness = CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", @workflow}], ["ci / required"])
    opts = [repo: "owner/repo", base_branch: "develop", config_fingerprint: "config-a", path: path, now: now]

    on_exit(fn ->
      File.rm(path)
      CiReadiness.clear_cached_result()
    end)

    assert :ok = CiReadiness.persist_assessment(readiness, Keyword.put(opts, :now, DateTime.add(now, -3_601, :second)))

    request_fun = fn %{url: url} ->
      cond do
        String.ends_with?(url, "/branches/develop") -> {:ok, %{status: 200, body: %{}}}
        String.ends_with?(url, "/repos/owner/repo") -> {:ok, %{status: 200, body: %{"default_branch" => "develop"}}}
        url =~ "/contents/.github/workflows" -> {:ok, %{status: 200, body: []}}
        true -> flunk("unexpected request: #{url}")
      end
    end

    assert {:ok, %{issues: [:no_pr_workflow, :no_required_check]}} =
             CiReadiness.dispatch_check(Keyword.put(opts, :request_fun, request_fun))
  end

  test "a newer persisted operator assessment replaces the live memory result" do
    path = Path.join(System.tmp_dir!(), "aiur-ci-readiness-#{System.unique_integer([:positive])}.json")
    now = DateTime.utc_now()
    readiness = CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", @workflow}], ["ci / required"])
    opts = [repo: "owner/repo", base_branch: "develop", config_fingerprint: "config-a", path: path, now: now]

    on_exit(fn ->
      File.rm(path)
      CiReadiness.clear_cached_result()
    end)

    assert :ok = CiReadiness.cache_result(CiReadiness.unavailable("develop", :ci_readiness_operator_token_required), opts)

    File.write!(
      path,
      Jason.encode!(%{
        "version" => 1,
        "assessed_at" => DateTime.to_iso8601(DateTime.add(now, 1, :second)),
        "scope" => %{"repo" => "owner/repo", "base_branch" => "develop", "config_fingerprint" => "config-a"},
        "result" => %{
          "ready" => true,
          "base_branch" => "develop",
          "workflow_paths" => readiness.workflow_paths,
          "workflow_check_names" => readiness.workflow_check_names,
          "required_checks" => readiness.required_checks,
          "required_check_identities" => readiness.required_check_identities,
          "issues" => []
        }
      })
    )

    assert CiReadiness.cached_result(Keyword.put(opts, :now, DateTime.add(now, 1, :second))) == readiness
  end

  test "bounds the complete inspection, including a blocked request" do
    request_fun = fn _request ->
      Process.sleep(50)
      {:ok, %{status: 200, body: %{}}}
    end

    assert {:error, {:github, :timeout, _}} =
             CiReadiness.check(repo: "owner/repo", base_branch: "develop", request_fun: request_fun, timeout_ms: 1)
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

  test "reports a missing workflow without needing Actions or Administration access" do
    request_fun = fn %{url: url} ->
      cond do
        String.ends_with?(url, "/branches/develop") -> {:ok, %{status: 200, body: %{}}}
        String.ends_with?(url, "/repos/owner/repo") -> {:ok, %{status: 200, body: %{"default_branch" => "develop"}}}
        url =~ "/contents/.github/workflows" -> {:ok, %{status: 200, body: []}}
        true -> flunk("unexpected privileged request: #{url}")
      end
    end

    assert {:ok, %{ready?: false, issues: [:no_pr_workflow, :no_required_check]}} =
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
    assert {:required_check_not_produced, ["ci / required"]} in issues
  end

  test "finds active workflow state on a later Actions page" do
    encoded = Base.encode64(@workflow)

    request_fun = fn %{url: url} ->
      cond do
        String.ends_with?(url, "/branches/develop") ->
          {:ok, %{status: 200, body: %{}}}

        String.ends_with?(url, "/repos/owner/repo") ->
          {:ok, %{status: 200, body: %{"default_branch" => "develop"}}}

        url =~ "/actions/workflows?per_page=100" ->
          {:ok,
           %{
             status: 200,
             body: %{"workflows" => [%{"path" => ".github/workflows/other.yml", "state" => "active"}]},
             headers: %{"link" => "<https://api.github.com/repos/owner/repo/actions/workflows?page=2>; rel=\"next\""}
           }}

        String.ends_with?(url, "/actions/workflows?page=2") ->
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

    assert {:ok, %{ready?: true}} = CiReadiness.inspect_repository(request_fun, "token", "owner", "repo", "develop")
  end

  test "presence-only inspection never uses Actions or Administration endpoints" do
    encoded = Base.encode64(@workflow)

    request_fun = fn %{url: url} ->
      cond do
        String.ends_with?(url, "/branches/develop") ->
          {:ok, %{status: 200, body: %{}}}

        String.ends_with?(url, "/repos/owner/repo") ->
          {:ok, %{status: 200, body: %{"default_branch" => "develop"}}}

        url =~ "/contents/.github/workflows" ->
          {:ok, %{status: 200, body: [%{"type" => "file", "path" => ".github/workflows/ci.yml", "url" => "workflow-url"}]}}

        url == "workflow-url?ref=develop" ->
          {:ok, %{status: 200, body: %{"content" => encoded}}}

        true ->
          flunk("unexpected privileged request: #{url}")
      end
    end

    assert {:error, :ci_readiness_operator_token_required} =
             CiReadiness.inspect_repository(request_fun, "token", "owner", "repo", "develop", workflow_presence_only: true)
  end

  test "presence-only inspection identifies a push-only workflow as missing a PR gate" do
    push_workflow = "on:\n  push:\n"

    request_fun = fn %{url: url} ->
      cond do
        String.ends_with?(url, "/branches/develop") ->
          {:ok, %{status: 200, body: %{}}}

        String.ends_with?(url, "/repos/owner/repo") ->
          {:ok, %{status: 200, body: %{"default_branch" => "develop"}}}

        url =~ "/contents/.github/workflows" ->
          {:ok, %{status: 200, body: [%{"type" => "file", "path" => ".github/workflows/push.yml", "url" => "push-workflow-url"}]}}

        url == "push-workflow-url?ref=develop" ->
          {:ok, %{status: 200, body: %{"content" => Base.encode64(push_workflow)}}}

        true ->
          flunk("unexpected privileged request: #{url}")
      end
    end

    assert {:ok, %{workflow_paths: [], issues: [:no_pr_workflow, :no_required_check]}} =
             CiReadiness.inspect_repository(request_fun, "token", "owner", "repo", "develop", workflow_presence_only: true)
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
