defmodule Aiur.CI.FailureDigestDerivedTest do
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

  test "known-flake partition and its coverage and test rollups are flake-only" do
    assert {:ok, digest} = build()
    assert digest.flake_only
    assert Enum.all?(digest.checks, & &1.flake_only)
    assert [%{identity: "Aiur.ExampleTest :: flaky test", classification: :known_flake}] = digest.tests
    assert {:ok, clean} = build(clean: true)
    assert digest.signature == clean.signature
  end

  test "an aggregate independent error prevents flake-only classification" do
    assert {:ok, digest} = build(extra: [%{"annotation_level" => "failure", "message" => "coverage below threshold"}])
    refute digest.flake_only
    assert [%{name: "test", flake_only: false}, %{name: "coverage", flake_only: false}, %{name: "coverage (3/4)", flake_only: true}] = digest.checks
    assert {:ok, flake} = build(id: "flake")
    refute digest.signature == flake.signature
  end

  test "missing, cyclic, unreadable and malformed dependency evidence stays conservative" do
    for dependencies <- [["missing"], ["test"], [], :malformed] do
      assert {:ok, digest} = build(id: inspect(dependencies), dependencies: dependencies)
      refute digest.flake_only
    end

    assert {:ok, unreadable} = build(id: "unreadable", extra: :unreadable)
    assert unreadable.tests == :unknown
    refute unreadable.flake_only
    assert {:ok, truncated} = build(id: "truncated", extra: [%{"title" => "aiur-test-failure", "message" => "truncated :: and 6 more"}])
    assert truncated.truncated
    refute truncated.flake_only
  end

  defp build(opts \\ []) do
    identity = "Aiur.ExampleTest :: flaky test"
    runs = Enum.with_index(["test", "coverage", "coverage (3/4)"], 1) |> Enum.map(fn {name, id} -> %{"id" => id, "name" => name, "status" => "completed", "conclusion" => "failure"} end)
    dependencies = Keyword.get(opts, :dependencies, ["coverage (3/4)"])
    message = if dependencies == :malformed, do: "broken", else: Jason.encode!(dependencies)
    derived = %{"title" => "aiur-derived-failure", "annotation_level" => "failure", "message" => message}
    exit = %{"annotation_level" => "failure", "message" => "Process completed with exit code 1."}
    extra = Keyword.get(opts, :extra, [])

    annotations = %{
      1 => [%{derived | "message" => Jason.encode!(["coverage", "coverage (3/4)"])}, exit],
      2 => if(extra == :unreadable, do: nil, else: [derived, exit] ++ extra),
      3 => [%{"title" => "aiur-test-failure", "message" => "known-flake :: " <> identity}]
    }

    request = fn %{url: url} ->
      cond do
        String.contains?(url, "/check-runs?") ->
          ok(%{"check_runs" => if(opts[:clean], do: [], else: runs)})

        String.ends_with?(url, "/status") ->
          ok(%{"statuses" => []})

        String.contains?(url, "/annotations?") ->
          [_, id] = Regex.run(~r{/check-runs/(\d+)/annotations}, url)

          annotation_response(annotations[String.to_integer(id)])

        String.contains?(url, "/contents/") ->
          ok(%{"encoding" => "base64", "content" => Base.encode64(identity)})

        String.contains?(url, "/issues?") ->
          ok([])
      end
    end

    FailureDigest.build(Keyword.get(opts, :id, "rollup"), request_fun: request)
  end

  defp annotation_response(nil), do: {:ok, %{status: 403, body: %{}}}
  defp annotation_response(body), do: ok(body)

  defp ok(body), do: {:ok, %{status: 200, body: body, headers: []}}
end
