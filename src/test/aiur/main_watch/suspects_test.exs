defmodule Aiur.MainWatch.SuspectsTest do
  use Aiur.TestSupport
  alias Aiur.MainWatch.Suspects

  setup do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    :ok
  end

  test "fetches only green-to-red commits and attributes early merges by PR or SHA" do
    request = fn %{url: url, caller: "main_watch_suspects", token: "test-token"} ->
      assert String.contains?(url, "/repos/owner/repo/commits/")
      sha = url |> URI.parse() |> Map.fetch!(:path) |> String.split("/") |> Enum.at(-2)

      case sha do
        "red" -> ok([pr(41), pr(42), Map.put(pr(99), "merged_at", nil)])
        "middle" -> ok([pr(42), pr(43), pr(44)])
        _ -> flunk("unexpected commit #{sha}")
      end
    end

    early = [%{pr: 41, pending_checks: ["tests"]}, %{"sha" => "middle", "pending_checks" => []}]
    result = Suspects.fetch("green", "red", ~w(newer red middle green older), early, token: "test-token", request_fun: request)
    assert result.complete
    assert Enum.map(result.pull_requests, &{&1.number, &1.sha, &1.early}) == [{41, "red", true}, {42, "red", :unknown}, {43, "middle", false}, {44, "middle", false}]
    assert Enum.all?(result.pull_requests, &(&1.url == "https://example.test/pr/#{&1.number}"))
  end

  test "failed association reads preserve other suspects but mark attribution incomplete" do
    request = fn %{url: url} ->
      if String.contains?(url, "/red/"), do: {:ok, %{status: 403, body: %{"message" => "forbidden"}}}, else: ok([pr(41)])
    end

    result = Suspects.fetch("green", "red", ~w(red middle green), [], token: "test-token", request_fun: request)
    refute result.complete
    assert Enum.map(result.pull_requests, & &1.number) == [41]
  end

  test "missing historical boundary and paginated responses stay incomplete" do
    opts = [token: "test-token", request_fun: fn _ -> ok([pr(41)]) end]
    result = Suspects.fetch("green", "red", ["red"], [], opts)
    refute result.complete
    assert Enum.map(result.pull_requests, & &1.number) == [41]

    missing_red = Suspects.fetch("green", "red", ["green"], [], Keyword.put(opts, :request_fun, fn _ -> flunk("no range to fetch") end))
    refute missing_red.complete
    assert missing_red.pull_requests == []

    request = fn _ -> {:ok, %{status: 200, body: [pr(41)], headers: [{"link", "<https://api.github.com/next>; rel=\"next\""}]}} end
    paginated = Suspects.fetch("green", "red", ~w(red green), [], token: "test-token", request_fun: request)
    refute paginated.complete
    assert paginated.pull_requests == []
  end

  defp pr(number), do: %{"number" => number, "html_url" => "https://example.test/pr/#{number}", "merged_at" => "2026-10-10T00:00:00Z"}
  defp ok(body), do: {:ok, %{status: 200, body: body, headers: []}}
end
