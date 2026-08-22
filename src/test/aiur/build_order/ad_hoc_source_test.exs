defmodule Aiur.BuildOrder.AdHocSourceTest do
  use Aiur.TestSupport

  alias Aiur.BuildOrder.AdHocSource
  alias Aiur.BuildOrder.AdHocSource.Snapshot
  alias Aiur.GitHub.ResourceStore

  @owner "owner"
  @repo "repo"

  setup do
    ensure_resource_store!()
    ensure_pubsub!()
    :ok
  end

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

  describe "event-sourced projection" do
    setup do
      ResourceStore.reset()
      on_exit(fn -> ResourceStore.reset() end)
      :ok
    end

    test "an issue labelled build-lane:adhoc appears in the overlay with zero listings" do
      test_pid = self()

      server =
        start_source(
          poll_on_start: false,
          request_fun: fn _request ->
            send(test_pid, :listed)
            {:ok, %{status: 200, body: [], headers: []}}
          end
        )

      deposit_issue(10, title: "Open ad hoc", labels: ["build-lane:adhoc", "phase:1"], state: "open")

      assert eventually(fn -> AdHocSource.snapshot(server).members != [] end)

      [member] = AdHocSource.snapshot(server).members
      assert member.identifier == "10"
      assert member.lifecycle == :open
      assert "build-lane:adhoc" in member.labels
      refute_received :listed
    end

    test "a closed adhoc issue stays in the overlay with lifecycle closed" do
      server = start_source(poll_on_start: false)
      deposit_issue(20, title: "Closed ad hoc", labels: ["build-lane:adhoc"], state: "closed")

      assert eventually(fn -> AdHocSource.snapshot(server).members != [] end)

      [member] = AdHocSource.snapshot(server).members
      assert member.lifecycle == :closed
    end

    test "removing the label removes the member" do
      server = start_source(poll_on_start: false)
      deposit_issue(10, title: "Ad hoc", labels: ["build-lane:adhoc"], state: "open")
      assert eventually(fn -> AdHocSource.snapshot(server).members != [] end)

      deposit_issue(10, title: "Ad hoc", labels: ["build-lane:runtime"], state: "open")
      assert eventually(fn -> AdHocSource.snapshot(server).members == [] end)
    end

    test "an issue without the label is not a member" do
      server = start_source(poll_on_start: false)
      deposit_issue(5, title: "Not adhoc", labels: ["build-lane:runtime"], state: "open")

      Process.sleep(100)
      assert AdHocSource.snapshot(server).members == []
    end

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

  # -- event-sourcing helpers -------------------------------------------------

  defp deposit_issue(number, attrs) do
    gh_issue =
      gh_issue(
        number,
        Keyword.get(attrs, :title, "Ticket #{number}"),
        Keyword.get(attrs, :labels, []),
        Keyword.get(attrs, :state, "open")
      )
      |> Map.put("created_at", "2026-07-14T12:00:00Z")
      |> Map.put("updated_at", "2026-07-15T09:00:00Z")

    ResourceStore.put_resource(ResourceStore.key(:issue, @owner, @repo, number), gh_issue,
      source: :webhook,
      version: Map.get(gh_issue, "updated_at")
    )

    ResourceStore.put_resource(ResourceStore.key(:issue_labels, @owner, @repo, number), gh_issue["labels"],
      source: :webhook,
      version: Map.get(gh_issue, "updated_at")
    )

    gh_issue
  end

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
