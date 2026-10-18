defmodule Aiur.GitHub.IssueLookupTest do
  use Aiur.TestSupport
  alias Aiur.GitHub.IssueLookup

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    :ok
  end

  test "reconciliation paginates the issue list and matches the complete nonce marker" do
    marker = "<!-- aiur-experiment-analysis request=req-one nonce=abcdef -->"

    request = fn req ->
      assert req.caller == "experiment_analysis_reconcile"

      if String.ends_with?(req.url, "page=2") do
        {:ok, %{status: 200, body: [%{"number" => 42, "html_url" => "https://github.com/owner/repo/issues/42", "body" => marker}]}}
      else
        assert req.url =~ "/repos/owner/repo/issues?state=all"

        {:ok,
         %{
           status: 200,
           headers: [{"link", "<https://api.github.com/repos/owner/repo/issues?page=2>; rel=\"next\""}],
           body: [%{"number" => 41, "body" => String.replace(marker, "abcdef", "different")}]
         }}
      end
    end

    assert {:ok, %{"number" => 42, "url" => "https://github.com/owner/repo/issues/42"}} = Aiur.Tracker.find_issue(marker, token: "fixture-token", request_fun: request)
  end

  test "a persisted creation window completes nonce reconciliation beyond ten pages of history" do
    since = DateTime.utc_now() |> DateTime.add(-300, :second) |> DateTime.to_iso8601()

    request = fn req ->
      if URI.decode_query(URI.parse(req.url).query)["since"] == since do
        {:ok, %{status: 200, body: []}}
      else
        page = URI.decode_query(URI.parse(req.url).query)["page"] || "1"
        next = [{"link", "<https://api.github.com/repos/owner/repo/issues?page=#{String.to_integer(page) + 1}>; rel=\"next\""}]
        {:ok, %{status: 200, headers: next, body: List.duplicate(%{"number" => 1, "body" => "old history"}, 100)}}
      end
    end

    assert {:error, :incomplete_issue_lookup} = Aiur.Tracker.find_issue("nonce", token: "fixture-token", request_fun: request)
    assert {:ok, nil} = Aiur.Tracker.find_issue("nonce", since: since, token: "fixture-token", request_fun: request)
  end

  test "incomplete, duplicate or failed lookups never prove absence" do
    marker = "nonce-marker"
    issue = %{"number" => 42, "html_url" => "https://github.com/owner/repo/issues/42", "body" => marker}
    assert {:error, :ambiguous_issue_lookup} = IssueLookup.find(marker, token: "fixture-token", request_fun: fn _ -> {:ok, %{status: 200, body: [issue, issue]}} end)
    next = [{"link", "<https://api.github.com/repos/owner/repo/issues?page=2>; rel=\"next\""}]
    assert {:error, :incomplete_issue_lookup} = IssueLookup.find(marker, token: "fixture-token", request_fun: fn _ -> {:ok, %{status: 200, headers: next, body: []}} end)
    assert {:error, :timeout} = IssueLookup.find(marker, token: "fixture-token", request_fun: fn _ -> {:error, :timeout} end)
    assert {:ok, nil} = IssueLookup.find(marker, token: "fixture-token", request_fun: fn _ -> {:ok, %{status: 200, body: [Map.put(issue, "pull_request", %{})]}} end)
  end
end
