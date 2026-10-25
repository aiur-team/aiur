defmodule Aiur.GitHub.CiReadiness.RepositoryErrorsTest do
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

  test "regression guard: reports a missing configured base branch only after establishing repository visibility" do
    parent = self()

    request_fun = fn %{url: url} ->
      send(parent, {:requested, url})

      if String.ends_with?(url, "/repos/owner/repo") do
        {:ok, %{status: 200, body: %{"default_branch" => "main"}}}
      else
        assert url =~ "/branches/develop"
        {:ok, %{status: 404, body: %{}}}
      end
    end

    assert {:ok, %{ready?: false, issues: [:base_branch_missing]}} =
             CiReadiness.inspect_repository(request_fun, "token", "owner", "repo", "develop")

    assert_receive {:requested, repo_url}, 1000
    assert String.ends_with?(repo_url, "/repos/owner/repo")
    assert_receive {:requested, branch_url}, 1000
    assert branch_url =~ "/branches/develop"
    refute_receive {:requested, _url}, 100
  end

  test "regression guard: classifies repository HTTP 403 as access failure without probing the branch" do
    parent = self()

    request_fun = fn %{url: url} ->
      send(parent, {:requested, url})
      assert String.ends_with?(url, "/repos/owner/repo")
      {:ok, %{status: 403, body: %{}}}
    end

    assert {:error, {:github, :http, %{status: 403}}} =
             CiReadiness.inspect_repository(request_fun, "token", "owner", "repo", "develop")

    assert_receive {:requested, repo_url}, 1000
    assert String.ends_with?(repo_url, "/repos/owner/repo")
    refute_receive {:requested, _url}, 100
  end

  test "reports org repository authorization when the repository 404s before requesting its branch" do
    parent = self()

    request_fun = fn %{url: url, token: token, credential_pinned?: true} ->
      send(parent, {:readiness_request, url, token})

      cond do
        String.ends_with?(url, "/repos/acme/private-repo") -> {:ok, %{status: 404, body: %{}}}
        String.ends_with?(url, "/orgs/acme") -> {:ok, %{status: 200, body: %{"login" => "acme"}}}
        true -> flunk("unexpected URL: #{url}")
      end
    end

    assert {:error, {:github_org_repository_not_accessible, %{organization: "acme", repo: "acme/private-repo", token_type: :classic_pat}}} =
             CiReadiness.inspect_repository(request_fun, "ghp_test-token", "acme", "private-repo", "main")

    assert_receive {:readiness_request, "https://api.github.com/repos/acme/private-repo", "ghp_test-token"}, 1000
    assert_receive {:readiness_request, "https://api.github.com/orgs/acme", "ghp_test-token"}, 1000
    refute_receive {:readiness_request, _url, _token}, 100
  end

  test "keeps a repository 404 ambiguous when the owner is not proven to be an organization" do
    request_fun = fn %{url: url, credential_pinned?: true} ->
      cond do
        String.ends_with?(url, "/repos/person/private-repo") -> {:ok, %{status: 404, body: %{}}}
        String.ends_with?(url, "/orgs/person") -> {:ok, %{status: 404, body: %{}}}
        true -> flunk("unexpected URL: #{url}")
      end
    end

    assert {:error, {:github, :http, %{status: 404}}} =
             CiReadiness.inspect_repository(request_fun, "github_pat_test", "person", "private-repo", "main")
  end

  test "keeps the repository 404 when the organization probe is forbidden" do
    request_fun = fn %{url: url, credential_pinned?: true} ->
      if String.ends_with?(url, "/orgs/acme"),
        do: {:ok, %{status: 403, body: %{}}},
        else: {:ok, %{status: 404, body: %{}}}
    end

    assert {:error, {:github, :http, %{status: 404}}} =
             CiReadiness.inspect_repository(request_fun, "ghp_test", "acme", "private-repo", "main")
  end

  test "preserves retryable organization-probe failures" do
    for status <- [429, 500] do
      request_fun = fn %{url: url, credential_pinned?: true} ->
        if String.ends_with?(url, "/orgs/acme"),
          do: {:ok, %{status: status, body: %{}}},
          else: {:ok, %{status: 404, body: %{}}}
      end

      assert {:error, {:github, reason, %{status: ^status}}} =
               CiReadiness.inspect_repository(request_fun, "ghp_test", "acme", "private-repo", "main")

      assert reason in [:http, :rate_limited]
    end
  end

  test "classifies the pinned credential by its documented prefix without returning its value" do
    for {token, token_type} <- [
          {"ghp_classic-secret", :classic_pat},
          {"github_pat_fine-secret", :fine_grained_pat},
          {"gho_oauth-secret", :oauth},
          {"ghs_installation-secret", :app_installation},
          {"unrecognized-secret", :unknown}
        ] do
      request_fun = fn %{url: url, credential_pinned?: true} ->
        if String.ends_with?(url, "/orgs/acme"),
          do: {:ok, %{status: 200, body: %{}}},
          else: {:ok, %{status: 404, body: %{}}}
      end

      assert {:error, {:github_org_repository_not_accessible, detail}} =
               CiReadiness.inspect_repository(request_fun, token, "acme", "private-repo", "main")

      assert detail.token_type == token_type
      Aiur.TestSupport.refute_leak(detail, token)
    end
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

  test "rejects a repository string without an owner/repo separator" do
    assert {:error, {:invalid_github_repo, "plain"}} = CiReadiness.check(repo: "plain", base_branch: "develop")
  end

  test "rejects a non-string, non-tuple repository" do
    assert {:error, :missing_github_repo} = CiReadiness.check(repo: 42, base_branch: "develop")
  end

  test "reports a DNS transport failure fetching the repository metadata" do
    request_fun = fn %{url: url} ->
      cond do
        String.ends_with?(url, "/branches/develop") -> {:ok, %{status: 200, body: %{}}}
        String.ends_with?(url, "/repos/owner/repo") -> {:error, :nxdomain}
      end
    end

    assert {:error, {:github, :dns, _detail}} = CiReadiness.inspect_repository(request_fun, "token", "owner", "repo", "develop")
  end

  test "reports an unexpected repository metadata response shape" do
    request_fun = fn %{url: url} ->
      cond do
        String.ends_with?(url, "/branches/develop") -> {:ok, %{status: 200, body: %{}}}
        String.ends_with?(url, "/repos/owner/repo") -> {:ok, "not-a-response"}
      end
    end

    assert {:error, :invalid_repository_response} = CiReadiness.inspect_repository(request_fun, "token", "owner", "repo", "develop")
  end

  test "reports a server error listing workflow contents" do
    request_fun = fn %{url: url} ->
      cond do
        String.ends_with?(url, "/branches/develop") -> {:ok, %{status: 200, body: %{}}}
        String.ends_with?(url, "/repos/owner/repo") -> {:ok, %{status: 200, body: %{"default_branch" => "develop"}}}
        url =~ "/contents/.github/workflows" -> {:ok, %{status: 500, body: %{}}}
      end
    end

    assert {:error, {:github, :http, %{status: 500}}} = CiReadiness.inspect_repository(request_fun, "token", "owner", "repo", "develop")
  end

  test "rejects a workflow whose contents are not valid base64" do
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
          {:ok, %{status: 200, body: %{"content" => "!!!not-base64!!!"}}}
      end
    end

    assert {:error, :invalid_workflow_content} = CiReadiness.inspect_repository(request_fun, "token", "owner", "repo", "develop")
  end

  test "reports a connectivity failure fetching a workflow file" do
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
          {:error, :econnrefused}
      end
    end

    assert {:error, {:github, :timeout, _detail}} = CiReadiness.inspect_repository(request_fun, "token", "owner", "repo", "develop")
  end

  test "reports a server error fetching branch protection" do
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
          {:ok, %{status: 500, body: %{}}}
      end
    end

    assert {:error, {:github, :http, %{status: 500}}} = CiReadiness.inspect_repository(request_fun, "token", "owner", "repo", "develop")
  end
end
