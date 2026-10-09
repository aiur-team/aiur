defmodule Aiur.CI.FailureDigestTest do
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

  test "clean commits do not buy annotation or classification reads" do
    request = fn %{url: url} ->
      cond do
        String.contains?(url, "/check-runs?") -> ok(%{"check_runs" => []})
        String.ends_with?(url, "/status") -> ok(%{"statuses" => []})
        true -> flunk("unexpected read: #{url}")
      end
    end

    assert {:ok, %FailureDigest{checks: [], tests: [], flake_only: false}} = FailureDigest.build("abc", request_fun: request)
  end

  test "lint without test annotations is a check-level failure" do
    assert {:ok, digest} = build([run(1, "lint")], %{1 => []})
    assert [%{name: "lint", url: "https://example.test/check/1", tests: [], flake_only: false}] = digest.checks
    assert digest.tests == []
    refute digest.flake_only
  end

  test "SHA-specific list classifies known flakes and excludes their check from signature" do
    identity = "Aiur.ExampleTest :: flaky test"
    assert {:ok, digest} = build([run(1)], %{1 => [annotation(identity)]}, known: "# comment\n#{identity}   \n")
    assert [%{identity: ^identity, classification: :known_flake}] = digest.tests
    assert digest.flake_only
    assert {:ok, clean} = build([], %{})
    assert digest.signature == clean.signature
  end

  test "open flake issues match exact identities and never longer test names" do
    identity = "Aiur.ExampleTest :: failure :: 100%"
    issues = [%{"title" => "a flake", "body" => "Fails in `#{identity}`."}]
    assert {:ok, digest} = build([run(1)], %{1 => [annotation(identity), annotation(identity <> " extra")]}, issues: issues)
    assert [%{classification: :known_flake}, %{classification: :new_failure}] = digest.tests
    refute digest.flake_only
  end

  test "annotation classification cannot override authoritative file and issue evidence" do
    assert {:ok, digest} = build([run(1)], %{1 => [annotation("Aiur.ExampleTest :: regression", "known-flake")]})
    assert [%{classification: :new_failure}] = digest.tests
    refute digest.flake_only
  end

  test "same failures on a rerun keep the signature and fetch new evidence" do
    parent = self()
    annotations = %{1 => [annotation("Aiur.ExampleTest :: regression")], 2 => [annotation("Aiur.ExampleTest :: regression")]}
    assert {:ok, first} = build([run(1)], annotations, parent: parent)
    assert_received {:annotations, 1}
    assert {:ok, cached} = build([run(1)], annotations, parent: parent)
    refute_received {:annotations, 1}
    assert cached == first
    assert {:ok, rerun} = build([run(2)], annotations, parent: parent)
    assert_received {:annotations, 2}
    assert rerun.signature == first.signature
  end

  test "403 and 5xx annotation reads remain unknown and retry rather than caching" do
    for status <- [403, 502] do
      assert {:ok, digest} = build([run(1)], %{1 => {:error_status, status}})
      assert digest.tests == :unknown
      refute digest.flake_only
      assert [%{name: "coverage (1/4)", tests: :unknown}] = digest.checks
    end

    assert {:ok, recovered} = build([run(1)], %{1 => [annotation("Aiur.ExampleTest :: regression")]})
    assert [%{classification: :new_failure}] = recovered.tests
  end

  test "truncated and malformed annotations cannot produce a flake-only digest" do
    identity = "Aiur.ExampleTest :: flaky test"
    truncated = %{"title" => "aiur-test-failure", "message" => "truncated :: and 6 more"}
    assert {:ok, digest} = build([run(1)], %{1 => [annotation(identity), truncated]}, known: identity)
    assert digest.truncated
    refute digest.flake_only
    assert {:ok, malformed} = build([run(2)], %{2 => [%{"title" => "aiur-test-failure", "message" => "broken"}]})
    assert malformed.tests == :unknown
    refute malformed.flake_only
  end

  test "non-test errors beside known flakes remain check-level failures" do
    identity = "Aiur.ExampleTest :: flaky test"
    error = %{"title" => "compile error", "message" => "compilation failed", "annotation_level" => "failure"}
    assert {:ok, digest} = build([run(1)], %{1 => [annotation(identity), error]}, known: identity)
    assert [%{classification: :known_flake}] = digest.tests
    refute digest.flake_only
  end

  test "mixed new failures have an order-independent signature, legacy statuses remain check-level" do
    annotations = %{1 => [annotation("Aiur.ExampleTest :: a")], 2 => [annotation("Aiur.ExampleTest :: b")]}
    assert {:ok, first} = build([run(1), run(2, "lint")], annotations)
    assert {:ok, reversed} = build([run(2, "lint"), run(1)], annotations)
    assert first.signature == reversed.signature
    assert {:ok, changed} = build([run(3)], %{3 => [annotation("Aiur.ExampleTest :: different")]})
    refute first.signature == changed.signature
    status = %{"statuses" => [%{"context" => "external", "state" => "error", "target_url" => "https://example.test/status"}]}
    assert {:ok, legacy} = build([], %{}, status: status)
    assert [%{name: "external", tests: [], flake_only: false}] = legacy.checks
    refute legacy.flake_only
  end

  defp run(id, name \\ "coverage (1/4)"), do: %{"id" => id, "name" => name, "status" => "completed", "conclusion" => "failure", "html_url" => "https://example.test/check/#{id}"}
  defp annotation(identity, class \\ "new-failure"), do: %{"title" => "aiur-test-failure", "message" => "#{class} :: #{identity}", "annotation_level" => "failure"}

  defp build(runs, annotations, opts \\ []) do
    request = fn %{url: url} ->
      cond do
        String.contains?(url, "/commits/abc/check-runs?") ->
          ok(%{"check_runs" => runs})

        String.ends_with?(url, "/commits/abc/status") ->
          ok(Keyword.get(opts, :status, %{"statuses" => []}))

        String.contains?(url, "/annotations?") ->
          annotation_response(url, annotations, opts)

        String.contains?(url, "/contents/") ->
          assert URI.decode_query(URI.parse(url).query)["ref"] == "abc"
          ok(%{"encoding" => "base64", "content" => Base.encode64(Keyword.get(opts, :known, ""))})

        String.contains?(url, "/issues?") ->
          ok(Keyword.get(opts, :issues, []))
      end
    end

    FailureDigest.build("abc", request_fun: request)
  end

  defp annotation_response(url, annotations, opts) do
    [_, id] = Regex.run(~r{/check-runs/(\d+)/annotations}, url)
    id = String.to_integer(id)
    if parent = opts[:parent], do: send(parent, {:annotations, id})

    case Map.fetch!(annotations, id) do
      {:error_status, status} -> {:ok, %{status: status, body: %{}}}
      body -> ok(body)
    end
  end

  defp ok(body), do: {:ok, %{status: 200, body: body, headers: []}}
end
