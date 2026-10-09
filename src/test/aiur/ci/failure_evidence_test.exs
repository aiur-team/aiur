defmodule Aiur.CI.FailureEvidenceTest do
  use Aiur.TestSupport
  alias Aiur.GitHub.{FailureEvidence, ResourceStore}

  setup do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    ResourceStore.clear(:flake_issues, "owner", "repo")
    on_exit(fn -> ResourceStore.clear(:flake_issues, "owner", "repo") end)
    :ok
  end

  test "annotations and open flake issues follow every page and exclude PRs" do
    next_annotations = "https://api.github.com/repos/owner/repo/check-runs/10/annotations?page=2"
    next_issues = "https://api.github.com/repos/owner/repo/issues?page=2"

    request = fn %{url: url, caller: "ci_failure_digest"} ->
      cond do
        url =~ "annotations?per_page" -> page([%{"title" => "first"}], next_annotations)
        url == next_annotations -> page([%{"title" => "last"}])
        url =~ "issues?state=open&labels=flake" -> page([%{"title" => "first issue"}], next_issues)
        url == next_issues -> page([%{"title" => "last issue"}, %{"pull_request" => %{}}])
      end
    end

    assert {:ok, [%{"title" => "first"}, %{"title" => "last"}]} = FailureEvidence.annotations(10, request_fun: request)
    assert {:ok, [%{"title" => "first issue"}, %{"title" => "last issue"}]} = FailureEvidence.flake_issues(request_fun: request)
    assert {:ok, [%{"title" => "first issue"}, %{"title" => "last issue"}]} = FailureEvidence.flake_issues(request_fun: fn _ -> flunk("cached issue listing should be reused") end)
  end

  test "a missing known-flaky file is empty, unreadable or invalid content is an error" do
    for {status, body, expected} <- [
          {404, %{}, {:ok, []}},
          {403, %{}, :error},
          {200, %{"encoding" => "base64", "content" => "invalid!"}, {:error, :invalid_known_flakes_file}}
        ] do
      result = FailureEvidence.known_flakes("sha", request_fun: fn _ -> {:ok, %{status: status, body: body}} end)
      if expected == :error, do: assert({:error, {:github, :http, %{status: 403}}} = result), else: assert(result == expected)
    end
  end

  test "a later-page failure never returns a partial annotation collection" do
    request = fn %{url: url} ->
      if url =~ "per_page", do: page([%{"title" => "first"}], "https://api.github.com/repos/owner/repo/check-runs/10/annotations?page=2"), else: {:ok, %{status: 502, body: %{}}}
    end

    assert {:error, {:github, :http, %{status: 502}}} = FailureEvidence.annotations(10, request_fun: request)
  end

  defp page(body, next \\ nil), do: {:ok, %{status: 200, body: body, headers: if(next, do: [{"link", "<#{next}>; rel=\"next\""}], else: [])}}
end
