defmodule Aiur.GitHub.Client.MergedPullRequestTest do
  # A worker whose ticket PR merged has no open PR to hand back; the no-op stop
  # asks for the branch's merged PR to send the ticket to review instead.
  use Aiur.TestSupport

  import Aiur.GitHub.ClientTestSupport

  alias Aiur.GitHub.Client

  setup do
    setup_client()
  end

  test "returns the merged PR for the branch and skips a closed unmerged one" do
    request_fun = fn %{method: :get, url: url} ->
      uri = URI.parse(url)
      assert uri.path =~ "/repos/owner/repo/pulls"
      assert %{"state" => "closed", "head" => "owner:aiur/480-mode"} = URI.decode_query(uri.query)

      {:ok, %{status: 200, body: [%{"number" => 510, "merged_at" => nil}, %{"number" => 517, "merged_at" => "2026-11-15T19:04:54Z"}]}}
    end

    assert {:ok, %{"number" => 517}} = Client.fetch_merged_pull_request_for_branch("aiur/480-mode", request_fun: request_fun)
  end

  test "returns nil when no PR from the branch merged" do
    request_fun = fn _ -> {:ok, %{status: 200, body: [%{"number" => 510, "merged_at" => nil}]}} end

    assert {:ok, nil} = Client.fetch_merged_pull_request_for_branch("aiur/480-mode", request_fun: request_fun)
  end

  test "surfaces a failed listing as an error" do
    request_fun = fn _ -> {:ok, %{status: 502, body: %{}}} end

    assert {:error, _reason} = Client.fetch_merged_pull_request_for_branch("aiur/480-mode", request_fun: request_fun)
  end
end
