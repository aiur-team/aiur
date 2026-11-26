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

  test "creation cutoff ignores recently updated old issues even after four days" do
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -4 * 86_400, :second)
    rows = for number <- 1..1100, do: issue(number, DateTime.add(cutoff, -number, :second), now, "old history")
    request = repository(rows)
    since = DateTime.to_iso8601(cutoff)

    assert {:error, :incomplete_issue_lookup} = IssueLookup.find("nonce", token: "fixture-token", request_fun: request)
    for page <- 1..10, do: assert_received({:lookup_page, ^page})
    refute_received {:lookup_page, _}
    assert {:ok, nil} = IssueLookup.find("nonce", since: since, token: "fixture-token", request_fun: request)
    assert_received {:lookup_page, 1}
    refute_received {:lookup_page, _}
  end

  test "a valid creation window finds a target beyond one thousand newer issues including its boundary" do
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -4 * 86_400, :second)
    newer = for number <- 1..1100, do: issue(number, DateTime.add(cutoff, number, :second), now, "different nonce")
    target = issue(1200, cutoff, now, "target nonce")
    request = repository([target | newer])

    assert {:ok, %{"number" => 1200}} = IssueLookup.find("target nonce", since: DateTime.to_iso8601(cutoff), token: "fixture-token", request_fun: request)
    assert_received {:lookup_page, 12}
  end

  # Future regression guard: legacy capped scans already refused a cyclic listing.
  test "a repeated pagination link cannot authorize a bounded absence result" do
    since = DateTime.to_iso8601(DateTime.utc_now())
    next = [{"link", "<https://api.github.com/repos/owner/repo/issues?page=2>; rel=\"next\""}]
    request = fn _ -> {:ok, %{status: 200, headers: next, body: []}} end
    assert {:error, :incomplete_issue_lookup} = IssueLookup.find("nonce", since: since, token: "fixture-token", request_fun: request)
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

  defp issue(number, created, updated, body) do
    %{"number" => number, "html_url" => "https://github.com/owner/repo/issues/#{number}", "body" => body, "created_at" => DateTime.to_iso8601(created), "updated_at" => DateTime.to_iso8601(updated)}
  end

  # Model GitHub's independent updated_at filter, creation ordering and 100-row pages.
  defp repository(rows) do
    parent = self()

    fn request ->
      query = URI.decode_query(URI.parse(request.url).query)
      page = String.to_integer(query["page"] || "1")
      send(parent, {:lookup_page, page})
      assert query["sort"] == "created"
      assert query["direction"] == "desc"
      assert query["per_page"] == "100"
      since = if query["since"], do: DateTime.from_iso8601(query["since"]) |> elem(1)
      eligible = rows |> Enum.filter(fn row -> is_nil(since) or DateTime.compare(DateTime.from_iso8601(row["updated_at"]) |> elem(1), since) == :gt end)
      ordered = Enum.sort_by(eligible, & &1["created_at"], :desc)
      body = Enum.slice(ordered, (page - 1) * 100, 100)
      next = URI.parse(request.url) |> Map.put(:query, URI.encode_query(Map.put(query, "page", page + 1))) |> URI.to_string()
      headers = if length(ordered) > page * 100, do: [{"link", "<#{next}>; rel=\"next\""}], else: []
      {:ok, %{status: 200, body: body, headers: headers}}
    end
  end
end
