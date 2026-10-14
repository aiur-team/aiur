defmodule Aiur.GitHub.CiReadiness.FetchErrorsTest do
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

  test "reports an invalid ruleset summary instead of guessing its rules" do
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

        url =~ "/rulesets" ->
          {:ok, %{status: 200, body: [%{"name" => "no-id"}]}}
      end
    end

    assert {:error, :invalid_ruleset_summary} = CiReadiness.inspect_repository(request_fun, "token", "owner", "repo", "develop")
  end

  test "detects a cyclic workflow state pagination response" do
    page_url = "https://api.github.com/repos/owner/repo/actions/workflows?page=2"

    request_fun = fn %{url: url} ->
      cond do
        String.ends_with?(url, "/branches/develop") ->
          {:ok, %{status: 200, body: %{}}}

        String.ends_with?(url, "/repos/owner/repo") ->
          {:ok, %{status: 200, body: %{"default_branch" => "develop"}}}

        url =~ "/actions/workflows?per_page=100" ->
          {:ok, %{status: 200, body: %{"workflows" => []}, headers: %{"link" => "<#{page_url}>; rel=\"next\""}}}

        url =~ "/actions/workflows?page=2" ->
          {:ok, %{status: 200, body: %{"workflows" => []}, headers: %{"link" => "<#{page_url}>; rel=\"next\""}}}

        url =~ "/contents/.github/workflows" ->
          {:ok, %{status: 200, body: [%{"type" => "file", "path" => ".github/workflows/ci.yml", "url" => "wf-url"}]}}
      end
    end

    assert {:error, :workflow_pagination_cycle} = CiReadiness.inspect_repository(request_fun, "token", "owner", "repo", "develop")
  end

  test "detects a cyclic ruleset pagination response" do
    encoded = Base.encode64(@workflow)
    page_url = "https://api.github.com/repos/owner/repo/rulesets?page=2"

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

        String.ends_with?(url, "/rulesets?includes_parents=true&per_page=100") ->
          {:ok, %{status: 200, body: [%{"id" => 1}], headers: %{"link" => "<#{page_url}>; rel=\"next\""}}}

        String.ends_with?(url, "/rulesets?page=2") ->
          {:ok, %{status: 200, body: [%{"id" => 2}], headers: %{"link" => "<#{page_url}>; rel=\"next\""}}}

        true ->
          flunk("unexpected request: #{url}")
      end
    end

    assert {:error, :ruleset_pagination_cycle} = CiReadiness.inspect_repository(request_fun, "token", "owner", "repo", "develop")
  end

  test "reports a transport failure when the bounded request process dies" do
    request_fun = fn _request -> exit(:boom) end

    assert {:error, {:github, :transport, _detail}} =
             CiReadiness.check(repo: "owner/repo", base_branch: "develop", request_fun: request_fun, timeout_ms: 500)
  end

  test "immediately times out when the inspection deadline has already passed" do
    request_fun = fn _request -> flunk("request should not run") end

    assert {:error, {:github, :timeout, _detail}} =
             CiReadiness.check(
               repo: "owner/repo",
               base_branch: "develop",
               request_fun: request_fun,
               timeout_ms: 1,
               deadline_at_ms: System.monotonic_time(:millisecond) - 100
             )
  end

  test "reports a server error fetching workflow state" do
    request_fun = fn %{url: url} ->
      cond do
        String.ends_with?(url, "/branches/develop") ->
          {:ok, %{status: 200, body: %{}}}

        String.ends_with?(url, "/repos/owner/repo") ->
          {:ok, %{status: 200, body: %{"default_branch" => "develop"}}}

        url =~ "/actions/workflows" ->
          {:ok, %{status: 500, body: %{}}}

        url =~ "/contents/.github/workflows" ->
          {:ok, %{status: 200, body: [%{"type" => "file", "path" => ".github/workflows/ci.yml", "url" => "wf-url"}]}}
      end
    end

    assert {:error, {:github, :http, %{status: 500}}} = CiReadiness.inspect_repository(request_fun, "token", "owner", "repo", "develop")
  end

  test "rejects a workflow state pagination URL outside the repository" do
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
             body: %{"workflows" => []},
             headers: %{"link" => "<https://evil.example.com/actions/workflows?page=2>; rel=\"next\""}
           }}

        url =~ "/contents/.github/workflows" ->
          {:ok, %{status: 200, body: [%{"type" => "file", "path" => ".github/workflows/ci.yml", "url" => "wf-url"}]}}
      end
    end

    assert {:error, :invalid_workflow_pagination_url} = CiReadiness.inspect_repository(request_fun, "token", "owner", "repo", "develop")
  end

  test "reports a server error fetching rulesets" do
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

        url =~ "/rulesets" ->
          {:ok, %{status: 500, body: %{}}}
      end
    end

    assert {:error, {:github, :http, %{status: 500}}} = CiReadiness.inspect_repository(request_fun, "token", "owner", "repo", "develop")
  end

  test "preserves GitHub's plan-limit message when rulesets are unavailable" do
    encoded = Base.encode64(@workflow)
    plan_limit_message = "Upgrade to GitHub Pro or make this repository public to enable this feature."

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

        url =~ "/rulesets" ->
          {:ok, %{status: 403, body: %{"message" => plan_limit_message}}}
      end
    end

    assert {:error, {:ci_readiness_plan_limit, ^plan_limit_message}} =
             CiReadiness.inspect_repository(request_fun, "token", "owner", "repo", "develop")
  end

  test "preserves GitHub's plan-limit message when branch protection is unavailable" do
    encoded = Base.encode64(@workflow)
    plan_limit_message = "Upgrade to GitHub Pro or make this repository public to enable this feature."

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
          {:ok, %{status: 403, body: %{"message" => plan_limit_message}}}

        url =~ "/rulesets" ->
          flunk("rulesets should not be fetched after branch protection reports a plan limit")
      end
    end

    assert {:error, {:ci_readiness_plan_limit, ^plan_limit_message}} =
             CiReadiness.inspect_repository(request_fun, "token", "owner", "repo", "develop")
  end

  test "keeps ordinary ruleset 403 responses classified as permission failures" do
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

        url =~ "/rulesets" ->
          {:ok, %{status: 403, body: %{"message" => "Resource not accessible by personal access token"}}}
      end
    end

    assert {:error, {:github, :http, %{status: 403}}} =
             CiReadiness.inspect_repository(request_fun, "token", "owner", "repo", "develop")
  end

  test "ignores non-workflow directory entries when collecting required checks" do
    request_fun = fn %{url: url} ->
      cond do
        String.ends_with?(url, "/branches/develop") ->
          {:ok, %{status: 200, body: %{}}}

        String.ends_with?(url, "/repos/owner/repo") ->
          {:ok, %{status: 200, body: %{"default_branch" => "develop"}}}

        url =~ "/contents/.github/workflows" ->
          {:ok,
           %{
             status: 200,
             body: [
               %{"type" => "dir", "path" => ".github/workflows/nested", "url" => "nested-url"}
             ]
           }}
      end
    end

    assert {:ok, %{ready?: false, issues: [:no_pr_workflow, :no_required_check]}} =
             CiReadiness.inspect_repository(request_fun, "token", "owner", "repo", "develop")
  end

  test "reports a server error fetching a ruleset detail" do
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
          {:ok, %{status: 200, body: [%{"id" => 12}]}}

        url =~ "/rulesets/12" ->
          {:ok, %{status: 500, body: %{}}}
      end
    end

    assert {:error, {:github, :http, %{status: 500}}} = CiReadiness.inspect_repository(request_fun, "token", "owner", "repo", "develop")
  end
end
