defmodule Aiur.OpenTicketSourceTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.{RequestOrigin, ResourceStore}
  alias Aiur.OpenTicketSource
  alias Aiur.OpenTicketSource.Snapshot
  alias Aiur.Webhooks.ModeRegistry

  @owner "owner"
  @repo "repo"

  setup do
    ensure_resource_store!()
    ensure_pubsub!()
    :ok
  end

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

    # The listing already carries every body, so the panel search reads
    # descriptions without a second request per ticket. Only the head is kept:
    # this snapshot is broadcast to every subscribed LiveView.
    test "retains a bounded excerpt of each issue body for the panel search" do
      body = String.duplicate("storm ", 400)
      request_fun = one_page([gh_issue(10, "Retry the dispatch", [], body), gh_issue(11, "No body", [], nil)])

      snapshot = OpenTicketSource.refresh_sync(start_source(request_fun: request_fun))

      excerpt = Enum.find(snapshot.tickets, &(&1.identifier == "10")).body_excerpt
      assert String.starts_with?(excerpt, "storm storm")
      assert String.length(excerpt) <= 1_000
      assert String.length(excerpt) < String.length(body)

      # A sub-binary would keep the whole body alive behind the excerpt, so the
      # bound would be a claim rather than a fact.
      assert :binary.referenced_byte_size(excerpt) == byte_size(excerpt)
      assert Enum.find(snapshot.tickets, &(&1.identifier == "11")).body_excerpt == nil
    end

    test "bounds the response so an oversized listing is never decoded in full" do
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

  test "propagates a LiveView request origin into an asynchronous refresh" do
    test_pid = self()

    request_fun = fn request ->
      send(test_pid, {:view_originated, RequestOrigin.view_originated?(), request})
      {:ok, %{status: 200, body: [], headers: []}}
    end

    server = start_source(request_fun: request_fun)

    RequestOrigin.carry(true, fn ->
      assert :ok = OpenTicketSource.refresh(server)
    end)

    assert_receive {:view_originated, true, %{method: :get}}, 2_000
  end

  test "keeps a background request origin out of an asynchronous refresh" do
    test_pid = self()

    request_fun = fn request ->
      send(test_pid, {:view_originated, RequestOrigin.view_originated?(), request})
      {:ok, %{status: 200, body: [], headers: []}}
    end

    server = start_source(request_fun: request_fun)

    assert :ok = OpenTicketSource.refresh(server)
    assert_receive {:view_originated, false, %{method: :get}}, 2_000
  end

  test "keeps the periodic poll outside the LiveView request origin" do
    test_pid = self()

    request_fun = fn request ->
      send(test_pid, {:view_originated, RequestOrigin.view_originated?(), request})
      {:ok, %{status: 200, body: [], headers: []}}
    end

    server = start_source(request_fun: request_fun)

    RequestOrigin.carry(true, fn -> send(server, :poll) end)

    assert_receive {:view_originated, false, %{method: :get}}, 2_000
  end

  describe "event-sourced projection" do
    setup do
      ResourceStore.reset()
      on_exit(fn -> ResourceStore.reset() end)
      :ok
    end

    # The acceptance for #2325: creating/labelling/closing/reopening an issue in
    # the GitHub UI is reflected on the Tickets panel with no fetch, because the
    # `issues` delivery is already deposited in the store before it is published
    # and this source rides that deposit. The `request_fun` below would record a
    # listing if one happened, so its silence is the whole assertion.
    test "an open issue deposited by a webhook appears in the projection with zero listings" do
      test_pid = self()

      server =
        start_source(
          poll_on_start: false,
          request_fun: fn _request ->
            send(test_pid, :listed)
            {:ok, %{status: 200, body: [], headers: []}}
          end
        )

      deposit_issue(10, title: "Event-sourced ticket", labels: ["agent:todo", "complexity:3"])

      assert eventually(fn -> OpenTicketSource.snapshot(server).tickets != [] end)

      snapshot = OpenTicketSource.snapshot(server)
      assert Enum.map(snapshot.tickets, & &1.identifier) == ["10"]
      assert Enum.find(snapshot.tickets, &(&1.identifier == "10")).labels == ["agent:todo", "complexity:3"]
      refute_received :listed
    end

    test "an unlabelled open ticket deposited by a webhook appears in the projection" do
      server = start_source(poll_on_start: false)
      deposit_issue(31, title: "Unlabelled backlog ticket", labels: [])

      assert eventually(fn -> OpenTicketSource.snapshot(server).tickets != [] end)
      assert Enum.map(OpenTicketSource.snapshot(server).tickets, & &1.identifier) == ["31"]
    end

    test "closing a held issue removes it from the projection" do
      server = start_source(poll_on_start: false)
      deposit_issue(10, state: "open")
      assert eventually(fn -> OpenTicketSource.snapshot(server).tickets != [] end)

      deposit_issue(10, state: "closed")
      assert eventually(fn -> OpenTicketSource.snapshot(server).tickets == [] end)
      assert OpenTicketSource.snapshot(server).tickets == []
    end

    test "a pull request served by the issues endpoint is excluded from the projection" do
      server = start_source(poll_on_start: false)
      deposit_issue(20, title: "A pull request", pull_request?: true)

      Process.sleep(100)
      assert OpenTicketSource.snapshot(server).tickets == []
    end

    test "deleting a held issue removes it from the projection" do
      server = start_source(poll_on_start: false)
      deposit_issue(10, state: "open")
      assert eventually(fn -> OpenTicketSource.snapshot(server).tickets != [] end)

      delete_issue(10)
      assert eventually(fn -> OpenTicketSource.snapshot(server).tickets == [] end)
    end

    # The gap-based re-convergence: a repo whose deliveries are known to be
    # dropped must re-list, because no event stream will converge it.
    test "a degraded event for the source's repo triggers a re-list" do
      test_pid = self()

      server =
        start_source(
          poll_on_start: false,
          request_fun: fn _request ->
            send(test_pid, :listed)
            {:ok, %{status: 200, body: [], headers: []}}
          end
        )

      send(server, {:webhook_degraded, "owner/repo"})
      assert_receive :listed, 2_000
    end

    test "a degraded event for another repo does not re-list" do
      test_pid = self()

      server =
        start_source(
          poll_on_start: false,
          request_fun: fn _request ->
            send(test_pid, :listed)
            {:ok, %{status: 200, body: [], headers: []}}
          end
        )

      send(server, {:webhook_degraded, "someone/else"})
      refute_receive :listed, 200
    end

    # The trailing edge of the gap: a resumed delivery proves the gap has closed,
    # so the source re-lists once to recover what the degraded window dropped.
    test "a recovered event for the source's repo triggers a re-list" do
      test_pid = self()

      server =
        start_source(
          poll_on_start: false,
          request_fun: fn _request ->
            send(test_pid, :listed)
            {:ok, %{status: 200, body: [], headers: []}}
          end
        )

      send(server, {:webhook_recovered, "owner/repo"})
      assert_receive :listed, 2_000
    end

    test "a recovered event for another repo does not re-list" do
      test_pid = self()

      server =
        start_source(
          poll_on_start: false,
          request_fun: fn _request ->
            send(test_pid, :listed)
            {:ok, %{status: 200, body: [], headers: []}}
          end
        )

      send(server, {:webhook_recovered, "someone/else"})
      refute_receive :listed, 200
    end

    # The divergence watermark (ViewStateSweep): GitHub observed ahead of the
    # store means a delivery was dropped, so the source re-lists to re-converge.
    test "a divergence event for the source's repo triggers a re-list" do
      test_pid = self()

      server =
        start_source(
          poll_on_start: false,
          request_fun: fn _request ->
            send(test_pid, :listed)
            {:ok, %{status: 200, body: [], headers: []}}
          end
        )

      send(server, {:view_state_diverged, "owner/repo"})
      assert_receive :listed, 2_000
    end

    test "a divergence event for another repo does not re-list" do
      test_pid = self()

      server =
        start_source(
          poll_on_start: false,
          request_fun: fn _request ->
            send(test_pid, :listed)
            {:ok, %{status: 200, body: [], headers: []}}
          end
        )

      send(server, {:view_state_diverged, "someone/else"})
      refute_receive :listed, 200
    end

    # Finding #2: a failed re-list must not be laundered back to `:available` by
    # the next unrelated delivery. A boot listing fails (unavailable, no
    # baseline), then a webhook deposits one open issue — the projection holds
    # real content, but the projection is *not* complete, so it must report
    # `:stale`, never `:available`.
    test "a delivery after a failed listing does not republish the projection as available" do
      server =
        start_source(
          poll_on_start: false,
          request_fun: failing()
        )

      assert OpenTicketSource.refresh_sync(server).status == :unavailable

      deposit_issue(10, title: "Deposited after the failed listing", labels: [])

      assert eventually(fn -> OpenTicketSource.snapshot(server).tickets != [] end)
      snapshot = OpenTicketSource.snapshot(server)

      assert snapshot.status == :stale,
             "a projection whose baseline listing failed must stay stale, never claim :available"

      assert Enum.map(snapshot.tickets, & &1.identifier) == ["10"]
    end

    # The acceptance's dropped-delivery path, at the integration seam: a real
    # ModeRegistry detects corroborated silence, degrades the repo, and the
    # source re-lists off that broadcast — no clock involved.
    test "a real ModeRegistry degradation re-lists the source" do
      test_pid = self()
      registry = :"mode_registry_#{System.unique_integer([:positive])}"
      now = ~U[2026-07-15 12:00:00Z]

      start_supervised!({ModeRegistry, name: registry, configured_repos: ["owner/repo"], silence_threshold_ms: 900_000, sweep_interval_ms: 3_600_000, alert_fun: fn _name, _message, _opts -> :ok end})

      start_source(
        poll_on_start: false,
        request_fun: fn _request ->
          send(test_pid, :listed)
          {:ok, %{status: 200, body: [], headers: []}}
        end
      )

      {:ok, _mode} = ModeRegistry.record_delivery("owner/repo", server: registry, at: now)
      {:ok, _mode} = ModeRegistry.record_activity("owner/repo", server: registry, at: DateTime.add(now, 901, :second))
      {:ok, ["owner/repo"]} = ModeRegistry.sweep(registry, DateTime.add(now, 1_802, :second))

      assert_receive :listed, 2_000
    end
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

  defp gh_issue(number, title, labels, body \\ nil) do
    %{
      "number" => number,
      "title" => title,
      "body" => body,
      "html_url" => "https://github.com/#{@owner}/#{@repo}/issues/#{number}",
      "state" => "open",
      "created_at" => "2026-07-14T12:00:00Z",
      "updated_at" => "2026-07-15T09:00:00Z",
      "labels" => Enum.map(labels, &%{"name" => &1})
    }
  end

  # -- event-sourcing helpers -------------------------------------------------

  defp deposit_issue(number, attrs) do
    gh_issue = gh_issue(number, Keyword.get(attrs, :title, "Ticket #{number}"), Keyword.get(attrs, :labels, []))

    gh_issue =
      gh_issue
      |> Map.put("state", Keyword.get(attrs, :state, "open"))
      |> maybe_pull_request(Keyword.get(attrs, :pull_request?, false))

    key = ResourceStore.key(:issue, @owner, @repo, number)
    ResourceStore.put_resource(key, gh_issue, source: :webhook, version: Map.get(gh_issue, "updated_at"))

    ResourceStore.put_resource(ResourceStore.key(:issue_labels, @owner, @repo, number), gh_issue["labels"],
      source: :webhook,
      version: Map.get(gh_issue, "updated_at")
    )

    gh_issue
  end

  defp delete_issue(number) do
    ResourceStore.drop_data(ResourceStore.key(:issue, @owner, @repo, number))
    ResourceStore.drop_data(ResourceStore.key(:issue_labels, @owner, @repo, number))
    :ok
  end

  defp maybe_pull_request(gh_issue, true), do: Map.put(gh_issue, "pull_request", %{"url" => "https://example.test/pull"})
  defp maybe_pull_request(gh_issue, false), do: gh_issue

  defp ensure_resource_store! do
    if Process.whereis(ResourceStore) == nil do
      Supervisor.restart_child(Aiur.Supervisor, ResourceStore)
    end

    :ok
  end

  defp ensure_pubsub! do
    unless Process.whereis(Aiur.PubSub) do
      {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)
      start_supervised!({Phoenix.PubSub, name: Aiur.PubSub})
    end

    :ok
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts <= 0 -> false
      true -> Process.sleep(10) && eventually(fun, attempts - 1)
    end
  end
end
