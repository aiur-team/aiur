defmodule Aiur.GitHub.CiReadiness.RulesetsTest do
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

    assert_receive {:readiness_url, repo_url}, 1000
    assert String.ends_with?(repo_url, "/repos/owner/repo")

    assert_receive {:readiness_url, branch_url}, 1000
    assert branch_url =~ "/branches/feature%2F%23%26gate"

    assert_receive {:readiness_url, workflow_url}, 1000
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

  test "ignores a ruleset that excludes the configured base branch" do
    encoded = Base.encode64(@workflow)

    request_fun = fn %{url: url} ->
      cond do
        String.ends_with?(url, "/branches/develop") ->
          {:ok, %{status: 200, body: %{}}}

        String.ends_with?(url, "/repos/owner/repo") ->
          {:ok, %{status: 200, body: %{"default_branch" => "develop"}}}

        url =~ "/actions/workflows" ->
          {:ok, %{status: 200, body: %{"workflows" => [%{"path" => ".github/workflows/ci.yml", "state" => "active"}]}}}

        url =~ "/contents/.github/workflows" ->
          {:ok, %{status: 200, body: [%{"type" => "file", "path" => ".github/workflows/ci.yml", "url" => "wf-url"}]}}

        url == "wf-url?ref=develop" ->
          {:ok, %{status: 200, body: %{"content" => encoded}}}

        url =~ "/protection" ->
          {:ok, %{status: 404, body: %{}}}

        url =~ "/rulesets?" ->
          {:ok, %{status: 200, body: [%{"id" => 16}]}}

        url =~ "/rulesets/16" ->
          {:ok,
           %{
             status: 200,
             body: %{
               "enforcement" => "active",
               "conditions" => %{"ref_name" => %{"include" => ["~ALL"], "exclude" => ["~DEFAULT_BRANCH"]}},
               "rules" => [%{"type" => "required_status_checks", "parameters" => %{"required_status_checks" => [%{"context" => "ci / required"}]}}]
             }
           }}
      end
    end

    assert {:ok, %{ready?: false, issues: [:no_required_check]}} =
             CiReadiness.inspect_repository(request_fun, "token", "owner", "repo", "develop")
  end

  test "ignores a ruleset whose required-status rule is not a map" do
    encoded = Base.encode64(@workflow)

    request_fun = fn %{url: url} ->
      cond do
        String.ends_with?(url, "/branches/develop") ->
          {:ok, %{status: 200, body: %{}}}

        String.ends_with?(url, "/repos/owner/repo") ->
          {:ok, %{status: 200, body: %{"default_branch" => "develop"}}}

        url =~ "/actions/workflows" ->
          {:ok, %{status: 200, body: %{"workflows" => [%{"path" => ".github/workflows/ci.yml", "state" => "active"}]}}}

        url =~ "/contents/.github/workflows" ->
          {:ok, %{status: 200, body: [%{"type" => "file", "path" => ".github/workflows/ci.yml", "url" => "wf-url"}]}}

        url == "wf-url?ref=develop" ->
          {:ok, %{status: 200, body: %{"content" => encoded}}}

        url =~ "/protection" ->
          {:ok, %{status: 404, body: %{}}}

        url =~ "/rulesets?" ->
          {:ok, %{status: 200, body: [%{"id" => 17}]}}

        url =~ "/rulesets/17" ->
          {:ok,
           %{
             status: 200,
             body: %{
               "enforcement" => "active",
               "conditions" => %{"ref_name" => %{"include" => ["~ALL"]}},
               "rules" => [%{"type" => "not_a_required_status_check", "parameters" => %{}}]
             }
           }}
      end
    end

    assert {:ok, %{ready?: false, issues: [:no_required_check]}} =
             CiReadiness.inspect_repository(request_fun, "token", "owner", "repo", "develop")
  end
end
