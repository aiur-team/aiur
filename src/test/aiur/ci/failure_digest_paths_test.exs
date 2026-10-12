defmodule Aiur.CI.FailureDigestPathsTest do
  use Aiur.TestSupport
  alias Aiur.CI.FailureDigest
  alias Aiur.GitHub.ResourceStore

  setup do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    ResourceStore.clear(:ci_failure_digest, "owner", "repo")
    ResourceStore.clear(:flake_issues, "owner", "repo")

    on_exit(fn ->
      ResourceStore.clear(:ci_failure_digest, "owner", "repo")
      ResourceStore.clear(:flake_issues, "owner", "repo")
    end)

    :ok
  end

  test "new failing tests retain paths and prove derived checks are test-only" do
    assert {:ok, digest} = build("paths")
    assert digest.test_only
    refute digest.flake_only
    assert Enum.all?(digest.checks, & &1.test_only)
    assert [%{identity: "ExampleTest :: fails", path: "src/test/example_test.exs", classification: :new_failure}] = digest.tests
  end

  test "independent aggregate failure cannot be classified as test-only" do
    assert {:ok, digest} = build("independent", [%{"annotation_level" => "failure", "message" => "coverage below threshold"}])
    refute digest.test_only
    assert Enum.find(digest.checks, &(&1.name == "test")).test_only == false
  end

  defp build(sha, extra \\ []) do
    request = fn %{url: url} ->
      cond do
        String.contains?(url, "/check-runs?") ->
          ok(%{"check_runs" => for({id, name} <- [{1, "coverage (1/4)"}, {2, "test"}], do: %{"id" => id, "name" => name, "status" => "completed", "conclusion" => "failure"})})

        String.ends_with?(url, "/status") ->
          ok(%{"statuses" => []})

        String.contains?(url, "/check-runs/1/annotations?") ->
          ok([%{"title" => "aiur-test-failure", "annotation_level" => "failure", "message" => "new-failure :: ExampleTest :: fails", "path" => "src/test/example_test.exs"}])

        String.contains?(url, "/check-runs/2/annotations?") ->
          ok([%{"title" => "aiur-derived-failure", "annotation_level" => "failure", "message" => Jason.encode!(["coverage (1/4)"])}] ++ extra)

        String.contains?(url, "/contents/") ->
          ok(%{"encoding" => "base64", "content" => ""})

        String.contains?(url, "/issues?") ->
          ok([])
      end
    end

    FailureDigest.build(sha, request_fun: request)
  end

  defp ok(body), do: {:ok, %{status: 200, body: body, headers: []}}
end
