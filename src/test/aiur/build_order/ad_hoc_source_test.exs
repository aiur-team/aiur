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

    # #2298 item 6: the recurring repo-wide listing carries a validator, so a
    # repeat refresh on an unchanged listing revalidates with `If-None-Match`
    # and reuses the held snapshot instead of paying full price.
    test "revalidates the listing and reuses the held snapshot on 304" do
      parent = self()
      etag = ~s("adhoc-v1")
      issues = [gh_issue(10, "Ad hoc", ["build-lane:adhoc"], "open")]

      request_fun = fn request ->
        case Map.get(request, :etag) do
          nil ->
            send(parent, :unconditional)
            {:ok, %{status: 200, body: issues, headers: [{"etag", etag}]}}

          ^etag ->
            send(parent, :conditional)
            {:ok, %{status: 304, headers: [{"etag", etag}]}}

          other ->
            flunk("unexpected If-None-Match validator #{inspect(other)}")
        end
      end

      server = start_source(request_fun: request_fun)

      fresh = AdHocSource.refresh_sync(server)
      assert fresh.status == :available and length(fresh.members) == 1
      assert_receive :unconditional

      revalidated = AdHocSource.refresh_sync(server)
      assert revalidated.status == :available
      assert length(revalidated.members) == 1
      assert_receive :conditional
    end

    # #2298 rework B2: the listing is `created`-desc, so page 1 is the newest
    # issues and freezes once no new adhoc issue is filed, while label changes
    # on older issues land on later pages. A page-1 `304` therefore cannot vouch
    # for a multi-page listing: it must be refetched every poll, or removing the
    # label from a page-2 issue would keep it in the held snapshot forever.
    test "a multi-page listing is refetched, never answered from a page-1 304" do
      etag = ~s("adhoc-v1")
      first_page = [gh_issue(10, "Ad hoc", ["build-lane:adhoc"], "open")]
      second_page = [gh_issue(20, "Ad hoc", ["build-lane:adhoc"], "closed")]
      next = ~s(<https://api.github.com/repos/owner/repo/issues?labels=build-lane%3Aadhoc&state=all&per_page=100&page=2>; rel="next")

      counter = start_supervised!({Agent, fn -> 0 end})

      request_fun = fn request ->
        refute Map.has_key?(request, :etag),
               "a multi-page held listing must never revalidate page 1"

        case Agent.get_and_update(counter, fn n -> {n, n + 1} end) do
          0 -> {:ok, %{status: 200, body: first_page, headers: [{"etag", etag}, {"link", next}]}}
          1 -> {:ok, %{status: 200, body: second_page, headers: []}}
          2 -> {:ok, %{status: 200, body: first_page, headers: [{"etag", etag}, {"link", next}]}}
          3 -> {:ok, %{status: 200, body: [gh_issue(20, "Ad hoc", [], "closed")], headers: []}}
        end
      end

      server = start_source(request_fun: request_fun)

      first = AdHocSource.refresh_sync(server)
      assert first.status == :available
      assert Enum.map(first.members, & &1.identifier) == ["10", "20"]

      # Page 2's issue lost the label between polls; because the held listing was
      # multi-page the poll refetches both pages and drops it from the snapshot.
      second = AdHocSource.refresh_sync(server)
      assert second.status == :available
      assert Enum.map(second.members, & &1.identifier) == ["10"]

      assert Agent.get(counter, & &1) == 4
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

    # Finding 5: `undemand/1` is the explicit counterpart to the monitor
    # release. The OpenTicketSource copy is pinned; this one must be too, or a
    # regression in the shared `ViewStateDemand` bookkeeping could ship on only
    # one side.
    test "undemand releases the caller's demand explicitly" do
      server = start_source(request_fun: one_page([]))

      assert :ok = AdHocSource.subscribe(server)
      assert eventually(fn -> AdHocSource.demander_count(server) == 1 end)

      assert :ok = AdHocSource.undemand(server)

      assert eventually(fn -> AdHocSource.demander_count(server) == 0 end)
      refute AdHocSource.demanded?(server)
    end

    # The 0->1 demander edge used to buy a fresh listing unconditionally, so a
    # LiveView reconnect would re-buy the whole labelled listing every time.
    # A snapshot younger than the courtesy floor means the page open is a
    # reconnect, and the held read is fresh enough to render (review finding 2).
    test "a first demander within the courtesy floor does not re-buy the listing" do
      test_pid = self()

      request_fun = fn %{method: :get} ->
        send(test_pid, :requested)
        {:ok, %{status: 200, body: [], headers: []}}
      end

      server = start_source(request_fun: request_fun)

      AdHocSource.refresh_sync(server)
      assert_receive :requested

      watcher = watch(server, test_pid)
      assert_receive :subscribed, 1_000
      assert eventually(fn -> AdHocSource.demander_count(server) == 1 end)

      refute_receive :requested, 500

      Process.exit(watcher, :kill)
    end

    test "a first demander after the courtesy floor buys the fresh listing" do
      test_pid = self()
      {:ok, clock} = Agent.start_link(fn -> ~U[2026-07-15 12:00:00Z] end)
      now = fn -> Agent.get(clock, & &1) end

      request_fun = fn %{method: :get} ->
        send(test_pid, :requested)
        {:ok, %{status: 200, body: [], headers: []}}
      end

      server = start_source(request_fun: request_fun, now_fun: now)

      AdHocSource.refresh_sync(server)
      assert_receive :requested

      Agent.update(clock, fn _ -> ~U[2026-07-15 12:00:31Z] end)

      watcher = watch(server, test_pid)
      assert_receive :subscribed, 1_000
      assert eventually(fn -> AdHocSource.demander_count(server) == 1 end)

      assert_receive :requested, 2_000

      Process.exit(watcher, :kill)
    end

    # Finding 3: a supervisor restart empties the demander set while the pages
    # that watch the source are still alive and still subscribed to the topic.
    # `reseed_demand/0` is the sweep's recovery — it re-registers the current
    # subscribers, so the gate cannot strand an open page in permanent silence.
    test "reseed_demand restores demand for pages still open after a restart" do
      test_pid = self()

      request_fun = fn %{method: :get} ->
        send(test_pid, :requested)
        {:ok, %{status: 200, body: [], headers: []}}
      end

      first = start_source(request_fun: request_fun)

      subscriber =
        spawn(fn ->
          AdHocSource.subscribe(first)
          send(test_pid, :subscribed)
          Process.sleep(:infinity)
        end)

      assert_receive :subscribed, 1_000
      assert eventually(fn -> AdHocSource.demander_count(first) == 1 end)

      Process.unlink(first)
      Process.exit(first, :kill)

      second = start_source(request_fun: request_fun)
      assert AdHocSource.demander_count(second) == 0, "a restarted source starts with no demanders"

      # The sweep's re-seed: subscriber presence restores the demand. The count
      # is asserted as "back above zero" rather than "exactly one" because this
      # module is async and a sibling test's watcher may share the topic.
      :ok = AdHocSource.reseed_demand(second)

      assert eventually(fn -> AdHocSource.demander_count(second) > 0 end),
             "reseed_demand did not re-register the still-open subscriber"

      assert AdHocSource.demanded?(second)

      Process.exit(subscriber, :kill)
    end

    # Finding 4: `demanded?` must not fold a source it cannot reach into
    # "nobody is watching"; the sweep should still attempt recovery.
    test "demanded? defaults to true when the source cannot answer" do
      server = start_source(request_fun: one_page([]))
      Process.unlink(server)
      Process.exit(server, :kill)

      assert AdHocSource.demanded?(server) == true
      assert AdHocSource.demander_count(server) == 0
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
