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

  describe "demand tracking" do
    test "subscribing registers the caller as a demander" do
      server = start_source(request_fun: one_page([]))
      parent = self()

      # The watcher stands in for a LiveView session: it subscribes and then
      # stays alive, exactly as an open page would.
      watcher = watch(server, parent)

      assert_receive :subscribed, 1_000

      assert eventually(fn -> AdHocSource.demanded?(server) end)
      assert eventually(fn -> AdHocSource.demander_count(server) == 1 end)

      Process.exit(watcher, :kill)
    end

    test "the first demander buys one refresh" do
      test_pid = self()

      request_fun = fn %{method: :get, url: url} ->
        send(test_pid, {:requested, url})
        {:ok, %{status: 200, body: [], headers: []}}
      end

      server = start_source(request_fun: request_fun)
      watch(server, test_pid)

      assert_receive :subscribed, 1_000
      assert_receive {:requested, url}, 2_000
      assert url =~ "labels=build-lane:adhoc"
    end

    test "closing the last session releases the demand; the count reaches zero" do
      server = start_source(request_fun: one_page([]))
      parent = self()

      watcher = watch(server, parent)

      assert_receive :subscribed, 1_000
      assert eventually(fn -> AdHocSource.demander_count(server) == 1 end)

      Process.exit(watcher, :kill)

      assert eventually(fn -> AdHocSource.demander_count(server) == 0 end)
      refute AdHocSource.demanded?(server)
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

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts <= 0 -> false
      true -> Process.sleep(10) && eventually(fun, attempts - 1)
    end
  end

  # Spawns a stand-in LiveView session: it subscribes to `server` as a demander
  # and then stays alive until the test kills it.
  defp watch(server, parent) do
    spawn(fn ->
      AdHocSource.subscribe(server)
      send(parent, :subscribed)
      Process.sleep(:infinity)
    end)
  end
end
