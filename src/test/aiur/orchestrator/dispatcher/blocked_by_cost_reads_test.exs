defmodule Aiur.Orchestrator.Dispatcher.BlockedByCostReadsTest do
  @moduledoc """
  Regression for #2714: after #2710 the dispatch gate re-read
  `/dependencies/blocked_by` unconditionally for every held dependent on every
  pass, and refreshed each one with an `issue_by_id` read first. On Khala the two
  were two thirds of the daemon's core spend.

  These tests run the production chain (default hydrator, `Client`, `Transport`)
  against a GitHub double and count the requests it receives.
  """

  use Aiur.DispatcherBlockedByCostSupport

  test "N held dependents across K passes cost N blocked_by reads and no issue_by_id reads" do
    dependents = ~w(14 15 16)
    passes = 5

    stub_github(fn _number -> [blocker_body("open", [%{"name" => "sym:human-review"}])] end)

    for _pass <- 1..passes, id <- dependents do
      state = run_pass(candidate(id))
      assert state.dispatch_declines[id] == :dependency
      refute Map.has_key?(state.running, id)
    end

    # One edge read per dependent in total: the first one proved blocker #53
    # open and deposited it, and every later pass read both from the store.
    assert blocked_by_reads() |> Enum.sort() == Enum.sort(dependents)

    # A held dependent is never refreshed: the dependency gate runs before the
    # `issue_by_id` refresh and its `dispatch_authorization` read.
    refute_received {:issue_fetch, _ids}
    refute_received {:github, _path}
  end

  test "a blocker closing in the :issue store releases its dependent on the next pass with no blocked_by read" do
    stub_github(fn _number -> [blocker_body("open", [%{"name" => "sym:human-review"}])] end)

    held = run_pass(candidate("14"))
    assert held.dispatch_declines["14"] == :dependency
    assert blocked_by_reads() == ["14"]

    # The tracker poll (or a webhook, or Aiur's own close) records the close.
    ResourceStore.put_resource(
      ResourceStore.key(:issue, "owner", "repo", "#{@blocker}"),
      blocker_body("closed", [], "2026-09-18T03:00:00Z"),
      source: :poll,
      version: "2026-09-18T03:00:00Z"
    )

    released = run_pass(candidate("14"), held)

    assert_receive {:agent_runner_run, dispatched, _recipient, _opts}, 1000
    assert dispatched.id == "14"
    assert Map.has_key?(released.running, "14")
    assert blocked_by_reads() == []
  end

  test "a blocker whose :issue record is older than the bound forces one re-read, which refreshes it" do
    stub_github(fn _number -> [blocker_body("open", [%{"name" => "sym:human-review"}])] end)

    assert run_pass(candidate("14")).dispatch_declines["14"] == :dependency
    assert blocked_by_reads() == ["14"]

    assert run_pass(candidate("14")).dispatch_declines["14"] == :dependency
    assert blocked_by_reads() == []

    age_resource(ResourceStore.key(:issue, "owner", "repo", "#{@blocker}"), :full_body_at_ms)

    # The edges are fresh again (an `issue_dependencies` webhook re-deposited
    # them), so only the blocker's aged `:issue` record can force this read.
    edges_key = ResourceStore.key(:issue_blocked_by, "owner", "repo", "14")
    ResourceStore.put_resource(edges_key, ResourceStore.data(edges_key), source: :webhook)

    assert run_pass(candidate("14")).dispatch_declines["14"] == :dependency
    assert blocked_by_reads() == ["14"]

    # That read proved #53 current again, so the next pass is free.
    assert run_pass(candidate("14")).dispatch_declines["14"] == :dependency
    assert blocked_by_reads() == []
  end

  # The fail-closed bound. The held edge list is empty and fresh, so within the
  # bound it is served; a blocker then added on GitHub's side, with no Aiur write
  # and no webhook delivery, must hold the dependent once the list is older than
  # `BoundedBlockedBy.max_age_ms/0` (15 minutes).
  test "a blocker added on GitHub's side with no Aiur write holds dispatch once the edge list is older than the bound" do
    edges_key = ResourceStore.key(:issue_blocked_by, "owner", "repo", "14")
    ResourceStore.put_resource(edges_key, [], source: :fetch)
    stub_github(fn _number -> [blocker_body("open", [%{"name" => "sym:todo"}])] end)

    age_resource(edges_key, :fetched_at_ms)

    state = run_pass(candidate("14"))

    assert state.dispatch_declines["14"] == :dependency
    refute Map.has_key?(state.running, "14")
    refute_received {:agent_runner_run, _dispatched, _recipient, _opts}
    assert blocked_by_reads() == ["14"]
  end

  test "a cross-repository blocker takes its state from its own repository's :issue record" do
    # A same-numbered issue in the tracker repository is closed. It must not
    # stand in for the open blocker in `other/lib`.
    ResourceStore.put_resource(
      ResourceStore.key(:issue, "owner", "repo", "#{@blocker}"),
      blocker_body("closed", []),
      source: :poll
    )

    foreign = Map.put(blocker_body("open", []), "repository_url", "https://api.github.com/repos/other/lib")
    stub_github(fn _number -> [foreign] end)

    for _pass <- 1..3 do
      assert run_pass(candidate("14")).dispatch_declines["14"] == :dependency
    end

    assert blocked_by_reads() == ["14"]
    assert %{"state" => "open"} = ResourceStore.data(ResourceStore.key(:issue, "other", "lib", "#{@blocker}"))
    assert %{"state" => "closed"} = ResourceStore.data(ResourceStore.key(:issue, "owner", "repo", "#{@blocker}"))
  end

  test "a blocked_by read never rolls back a newer :issue record" do
    # The store already holds #53 closed at 03:00. A lagging dependencies read
    # still embeds it open at 02:00.
    ResourceStore.put_resource(
      ResourceStore.key(:issue, "owner", "repo", "#{@blocker}"),
      blocker_body("closed", [], "2026-09-18T03:00:00Z"),
      source: :webhook,
      version: "2026-09-18T03:00:00Z"
    )

    stub_github(fn _number -> [blocker_body("open", [%{"name" => "sym:human-review"}])] end)

    assert run_pass(candidate("14")).dispatch_declines["14"] == :dependency
    assert blocked_by_reads() == ["14"]
    assert %{"state" => "closed"} = ResourceStore.data(ResourceStore.key(:issue, "owner", "repo", "#{@blocker}"))

    # The next pass reads the held edge and the newer record, and dispatches.
    released = run_pass(candidate("14"))
    assert Map.has_key?(released.running, "14")
    assert blocked_by_reads() == []
  end

  test "a blocker closed on GitHub with no running entry and no store write releases its dependent after the next poll, for one read" do
    open_blocker = [blocker_body("open", [%{"name" => "sym:human-review"}])]
    stub_github(fn _number -> open_blocker end)

    assert run_pass(candidate("14")).dispatch_declines["14"] == :dependency
    assert blocked_by_reads() == ["14"]

    # Closed by a manual close, or by a PR whose branch is not `aiur/53`: no
    # agent, no mutation, no webhook. Only the open-issue poll can see it.
    Process.sleep(2)
    assert {:ok, _candidates, _cache} = poll_open_issues()

    closed_blocker = [blocker_body("closed", [], "2026-09-18T03:00:00Z")]
    stub_github(fn _number -> closed_blocker end)

    released = run_pass(candidate("14"))

    assert_receive {:agent_runner_run, dispatched, _recipient, _opts}, 1000
    assert dispatched.id == "14"
    assert Map.has_key?(released.running, "14")
    assert blocked_by_reads() == ["14"]
    assert %{"state" => "closed"} = ResourceStore.data(ResourceStore.key(:issue, "owner", "repo", "#{@blocker}"))

    # The re-read wrote the close back, so later passes need no read.
    run_pass(candidate("14"), released)
    assert blocked_by_reads() == []
  end

  test "a failed open-issue poll gives no close signal" do
    stub_github(fn _number -> [blocker_body("open", [%{"name" => "sym:human-review"}])] end)

    assert run_pass(candidate("14")).dispatch_declines["14"] == :dependency
    assert blocked_by_reads() == ["14"]

    Process.sleep(2)
    assert {:error, _reason} = poll_open_issues(500)
    stub_github(fn _number -> [blocker_body("open", [%{"name" => "sym:human-review"}])] end)

    assert run_pass(candidate("14")).dispatch_declines["14"] == :dependency
    assert blocked_by_reads() == []
  end

  test "an open-issue listing taken before the blocker's record gives no close signal" do
    # The listing predates the blocker (it opened, or reopened, afterwards).
    assert {:ok, _candidates, _cache} = poll_open_issues()
    Process.sleep(2)

    stub_github(fn _number -> [blocker_body("open", [%{"name" => "sym:human-review"}])] end)

    for _pass <- 1..3 do
      assert run_pass(candidate("14")).dispatch_declines["14"] == :dependency
    end

    assert blocked_by_reads() == ["14"]
  end

  test "a label write does not make a blocker's old state look fresh" do
    stub_github(fn _number -> [blocker_body("open", [%{"name" => "sym:human-review"}])] end)

    assert run_pass(candidate("14")).dispatch_declines["14"] == :dependency
    assert blocked_by_reads() == ["14"]

    blocker_key = ResourceStore.key(:issue, "owner", "repo", "#{@blocker}")
    age_resource(blocker_key, :full_body_at_ms)
    [{^blocker_key, entry}] = :ets.lookup(ResourceStore.Table, blocker_key)
    old_body_at_ms = entry.full_body_at_ms

    # Only the state is aged; the label and edge writes must not renew it.
    WriteThrough.issue_labels(@blocker, [%{"name" => "sym:rework"}])
    edges_key = ResourceStore.key(:issue_blocked_by, "owner", "repo", "14")
    ResourceStore.put_resource(edges_key, ResourceStore.data(edges_key), source: :webhook)

    assert {:ok, %{data: %{"labels" => [%{"name" => "sym:rework"}]}, full_body_at_ms: ^old_body_at_ms}} =
             ResourceStore.fetch(blocker_key)

    assert run_pass(candidate("14")).dispatch_declines["14"] == :dependency
    assert blocked_by_reads() == ["14"]
  end
end
