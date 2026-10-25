defmodule Aiur.Events.GithubCommentsPollerListingTest do
  use Aiur.TestSupport
  use Aiur.TestSupport.EventTicket
  import Aiur.TestSupport.CommentsPollerFixture

  alias Aiur.Events.GithubCommentsPoller

  setup :comments_poller_env

  test "shares one branch listing across all REST-fallback targets in a poll" do
    parent = self()
    targets = ["42", "43", "44"]

    request_fun = fn %{url: url} ->
      if String.contains?(url, "/pulls?") do
        send(parent, :open_pull_request_listing)
        {:ok, %{status: 200, headers: [{"etag", ~s("open-prs")}], body: []}}
      else
        send(parent, {:issue_comments, url})
        {:ok, %{status: 200, body: []}}
      end
    end

    assert {:ok, %{count: 0, errors: []}} =
             GithubCommentsPoller.poll(targets,
               since: "2026-06-24T11:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )

    assert_receive :open_pull_request_listing, 1000

    requested =
      for _target <- targets do
        assert_receive {:issue_comments, url}, 1000
        url
      end

    assert Enum.all?(targets, fn target -> Enum.any?(requested, &String.contains?(&1, "/issues/#{target}/comments?")) end)
    refute_receive :open_pull_request_listing, 100
  end
end
