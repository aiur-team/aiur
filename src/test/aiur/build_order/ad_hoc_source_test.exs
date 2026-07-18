defmodule Aiur.BuildOrder.AdHocSourceTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildOrder.AdHocSource
  alias Aiur.BuildOrder.AdHocSource.Snapshot

  @owner "owner"
  @repo "repo"

  describe "refresh_sync/1" do
    test "lists build-lane:adhoc issues including closed ones with lifecycle" do
      request_fun =
        one_page([
          gh_issue(10, "Open ad hoc", ["build-lane:adhoc", "phase:1"], "open"),
          gh_issue(20, "Closed ad hoc", ["build-lane:adhoc"], "closed")
        ])

      snapshot = AdHocSource.refresh_sync(start_source(request_fun: request_fun))

      assert %Snapshot{status: :available, generation: 1} = snapshot
      assert Enum.map(snapshot.members, & &1.identifier) == ["10", "20"]

      [open, closed] = snapshot.members
      assert open.lifecycle == :open and "build-lane:adhoc" in open.labels
      assert closed.lifecycle == :closed
    end

    test "drops issues that do not carry the adhoc label" do
      request_fun = one_page([gh_issue(5, "Not adhoc", ["build-lane:runtime"], "open")])

      snapshot = AdHocSource.refresh_sync(start_source(request_fun: request_fun))

      assert snapshot.status == :available
      assert snapshot.members == []
    end

    test "keeps the last-known-good snapshot and reports stale on a later failure" do
      request_fun = flip(one_page([gh_issue(10, "Ad hoc", ["build-lane:adhoc"], "open")]), failing())
      server = start_source(request_fun: request_fun)

      fresh = AdHocSource.refresh_sync(server)
      assert fresh.status == :available and length(fresh.members) == 1

      stale = AdHocSource.refresh_sync(server)
      assert stale.status == :stale
      assert length(stale.members) == 1, "last-known-good members are retained"
    end

    test "reports unavailable when it never succeeded" do
      snapshot = AdHocSource.refresh_sync(start_source(request_fun: failing()))

      assert snapshot.status == :unavailable
      assert snapshot.members == []
    end

    test "reports unavailable when the repository cannot be resolved" do
      snapshot =
        AdHocSource.refresh_sync(start_source(repo_fun: fn -> {:error, :no_repo} end, request_fun: failing()))

      assert snapshot.status == :unavailable
    end
  end

  defp start_source(opts) do
    defaults = [
      name: nil,
      poll_on_start: false,
      repo_fun: fn -> {:ok, {@owner, @repo}} end,
      token_fun: fn -> {:ok, "token"} end,
      now_fun: fn -> ~U[2026-07-15 12:00:00Z] end,
      label_prefix: "aiur"
    ]

    {:ok, pid} = AdHocSource.start_link(Keyword.merge(defaults, opts))
    pid
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

  defp gh_issue(number, title, labels, state) do
    %{
      "number" => number,
      "title" => title,
      "html_url" => "https://github.com/#{@owner}/#{@repo}/issues/#{number}",
      "state" => state,
      "labels" => Enum.map(labels, &%{"name" => &1})
    }
  end
end
