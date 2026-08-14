defmodule Aiur.OpenTicketSourceTest do
  use ExUnit.Case, async: true

  alias Aiur.OpenTicketSource
  alias Aiur.OpenTicketSource.Snapshot

  @owner "owner"
  @repo "repo"

  describe "refresh_sync/1" do
    test "lists every open issue, newest first, whatever labels it carries" do
      request_fun =
        one_page([
          gh_issue(10, "Labelled", ["agent:todo", "complexity:3"]),
          gh_issue(31, "Unlabelled backlog ticket", [])
        ])

      snapshot = OpenTicketSource.refresh_sync(start_source(request_fun: request_fun))

      assert %Snapshot{status: :available, generation: 1} = snapshot
      assert Enum.map(snapshot.tickets, & &1.identifier) == ["31", "10"]
      assert Enum.find(snapshot.tickets, &(&1.identifier == "10")).labels == ["agent:todo", "complexity:3"]
    end

    # GitHub serves pull requests from the issues endpoint, so a PR would
    # otherwise appear in the Tickets panel as a ticket nobody can dispatch.
    test "excludes pull requests served by the issues endpoint" do
      pull_request = 20 |> gh_issue("A pull request", []) |> Map.put("pull_request", %{"url" => "https://example.test/pull/20"})
      request_fun = one_page([gh_issue(10, "A ticket", []), pull_request])

      snapshot = OpenTicketSource.refresh_sync(start_source(request_fun: request_fun))

      assert Enum.map(snapshot.tickets, & &1.identifier) == ["10"]
    end

    test "requests the open listing without a label filter" do
      test_pid = self()

      request_fun = fn %{method: :get, url: url} ->
        send(test_pid, {:requested, url})
        {:ok, %{status: 200, body: [], headers: []}}
      end

      OpenTicketSource.refresh_sync(start_source(request_fun: request_fun))

      assert_received {:requested, url}
      assert url =~ "state=open"
      refute url =~ "labels="
    end

    test "keeps the last-known-good listing and reports stale on a later failure" do
      request_fun = flip(one_page([gh_issue(10, "A ticket", [])]), failing())
      server = start_source(request_fun: request_fun)

      assert OpenTicketSource.refresh_sync(server).status == :available

      stale = OpenTicketSource.refresh_sync(server)

      assert stale.status == :stale
      assert Enum.map(stale.tickets, & &1.identifier) == ["10"]
    end

    test "a first failure is unavailable rather than an empty healthy listing" do
      snapshot = OpenTicketSource.refresh_sync(start_source(request_fun: failing()))

      assert snapshot.status == :unavailable
      assert snapshot.tickets == []
    end

    # A Linear or in-memory tracker has no such listing at all; calling that an
    # outage would tell the operator to retry something that cannot succeed.
    test "a non-GitHub tracker is reported unsupported without any request" do
      request_fun = fn _request -> flunk("must not call GitHub for a non-GitHub tracker") end

      snapshot = OpenTicketSource.refresh_sync(start_source(request_fun: request_fun, github_fun: fn -> false end))

      assert snapshot.status == :unsupported
      assert snapshot.tickets == []
    end

    test "follows pagination and marks a listing cut short by the page budget" do
      request_fun = paging(20)

      snapshot = OpenTicketSource.refresh_sync(start_source(request_fun: request_fun))

      assert snapshot.status == :available
      assert snapshot.truncated?
      # Ten pages of one ticket each, newest first.
      assert length(snapshot.tickets) == 10
    end

    test "a listing that ends inside the page budget is not marked truncated" do
      snapshot = OpenTicketSource.refresh_sync(start_source(request_fun: paging(2)))

      assert length(snapshot.tickets) == 2
      refute snapshot.truncated?
    end

    test "bounds the response so discarded issue bodies are never decoded in full" do
      test_pid = self()

      request_fun = fn request ->
        send(test_pid, {:bounded, Map.get(request, :max_response_bytes)})
        {:ok, %{status: 200, body: [], headers: []}}
      end

      OpenTicketSource.refresh_sync(start_source(request_fun: request_fun))

      assert_received {:bounded, bytes} when is_integer(bytes) and bytes > 0
    end
  end

  test "snapshot/1 answers unavailable instead of exiting when the poller is gone" do
    assert %Snapshot{status: :unavailable} = OpenTicketSource.snapshot(:no_such_open_ticket_source)
  end

  defp start_source(opts) do
    defaults = [
      name: nil,
      poll_on_start: false,
      repo_fun: fn -> {:ok, {@owner, @repo}} end,
      token_fun: fn -> {:ok, "token"} end,
      now_fun: fn -> ~U[2026-07-15 12:00:00Z] end,
      label_prefix: "aiur",
      github_fun: fn -> true end
    ]

    {:ok, pid} = OpenTicketSource.start_link(Keyword.merge(defaults, opts))
    pid
  end

  # Serves `pages` pages of one issue each, linking to the next until exhausted.
  defp paging(pages) do
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    fn %{method: :get} ->
      page = Agent.get_and_update(agent, &{&1, &1 + 1})
      headers = if page + 1 < pages, do: [{"link", ~s(<https://api.github.test/next?page=#{page + 2}>; rel="next")}], else: []
      {:ok, %{status: 200, body: [gh_issue(100 + page, "Page #{page}", [])], headers: headers}}
    end
  end

  defp one_page(issues) do
    fn %{method: :get} -> {:ok, %{status: 200, body: issues, headers: []}} end
  end

  defp failing do
    fn %{method: :get} -> {:ok, %{status: 502, body: "bad gateway", headers: []}} end
  end

  # Returns the first response on the first call, then the second thereafter.
  defp flip(first, rest) do
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    fn request ->
      count = Agent.get_and_update(agent, &{&1, &1 + 1})
      if count == 0, do: first.(request), else: rest.(request)
    end
  end

  defp gh_issue(number, title, labels) do
    %{
      "number" => number,
      "title" => title,
      "html_url" => "https://github.com/#{@owner}/#{@repo}/issues/#{number}",
      "state" => "open",
      "created_at" => "2026-07-14T12:00:00Z",
      "updated_at" => "2026-07-15T09:00:00Z",
      "labels" => Enum.map(labels, &%{"name" => &1})
    }
  end
end
