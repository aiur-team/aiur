defmodule Aiur.BuildOrder.History.BackfillQueryTest do
  use ExUnit.Case, async: true
  alias Aiur.BuildOrder.History.{BackfillQuery, Row}
  alias Aiur.GitHub.GraphQLCost
  alias Aiur.HistoryBackfillFixture, as: F
  @at ~U[2026-10-08 11:00:00Z]
  @repo %{owner: "acme", repository: "widgets"}
  defp events(nodes), do: BackfillQuery.events(F.page(nodes), @repo, "aiur", @at)

  test "query walks oldest first and prices below the transport ceiling" do
    query = BackfillQuery.query()
    assert query =~ "orderBy: {field: CREATED_AT, direction: ASC}"
    assert query =~ "issues(first: 100, after: $cursor"
    refute query =~ "states:"
    assert query =~ "SUB_ISSUE_ADDED_EVENT"
    assert query =~ "actor { login }"
    assert query =~ "id number title state stateReason createdAt updatedAt closedAt"
    assert :ok = GraphQLCost.check(query, [])
    assert BackfillQuery.variables("acme", "widgets", "c1") == %{"owner" => "acme", "repo" => "widgets", "cursor" => "c1"}
  end

  test "normalizer preserves closing PR, foreign blockers, join times and actor" do
    closed = %{"__typename" => "ClosedEvent", "createdAt" => F.time(), "closer" => %{"number" => 40, "mergedAt" => F.time()}}
    connected = %{"__typename" => "ConnectedEvent", "createdAt" => "2026-10-08T11:00:00Z", "subject" => %{"number" => 50, "mergedAt" => F.time()}}
    child = %{"__typename" => "SubIssueAddedEvent", "createdAt" => F.time(), "subIssue" => F.ref(9)}

    node =
      F.node(7, %{
        "blockedBy" => F.blockers([F.ref(5, "other-org", "lib")]),
        "parent" => F.ref(1),
        "timelineItems" => F.timeline([F.label("feature:home"), F.label("feature:old", "UnlabeledEvent", F.time(), nil), closed, connected, child])
      })

    assert {:ok, [event], _info} = events([node])
    assert event.observed_at == @at
    assert event.source == :backfill
    assert event.fields.blocked_by == [%{owner: "other-org", repository: "lib", number: 5}]
    assert event.fields.parent == %{owner: "acme", repository: "widgets", number: 1}
    assert event.fields.node_id == "I_7"
    assert event.fields.updated_at == ~U[2026-10-08 10:00:00Z]
    assert event.fields.last_closed_at == ~U[2026-10-08 10:00:00Z]
    assert event.fields.merged_at == ~U[2026-10-08 10:00:00Z]
    assert event.fields.pr_number == 40

    assert event.fields.label_events == [
             %{label: "feature:home", action: :labeled, at: ~U[2026-10-08 10:00:00Z], actor: "kev"},
             %{label: "feature:old", action: :unlabeled, at: ~U[2026-10-08 10:00:00Z], actor: :unknown}
           ]

    assert event.fields.sub_issues_added == [%{ref: %{owner: "acme", repository: "widgets", number: 9}, at: ~U[2026-10-08 10:00:00Z]}]
    assert {:ok, ^event} = Row.validate_event(event)
  end

  test "incomplete connections leave latest merge facts unknown" do
    pr = %{"__typename" => "ClosedEvent", "createdAt" => F.time(), "closer" => %{"number" => 40, "mergedAt" => F.time()}}
    node = F.node(7, %{"timelineItems" => F.timeline([pr], true), "labels" => %{"nodes" => [], "totalCount" => 101}, "blockedBy" => F.blockers([F.ref(1)], true, "b1")})
    assert {:ok, [event], info} = events([node])
    assert event.fields.timeline_complete == false
    assert event.fields.labels_complete == false
    assert event.fields.blocked_by_complete == false
    refute Map.has_key?(event.fields, :merged_at)
    refute Map.has_key?(event.fields, :pr_number)
    assert [%{"number" => 7, "cursor" => "b1", "observed_at" => "2026-10-08T11:00:00Z"}] = info["pending_blockers"]
  end

  test "only configured in-progress labels set the earliest signal" do
    labels = [
      F.label("agent:in-progress", "LabeledEvent", "2026-10-08T09:00:00Z"),
      F.label("aiur:in-progress", "UnlabeledEvent", "2026-10-08T09:30:00Z"),
      F.label("aiur:in-progress", "LabeledEvent", "2026-10-08T11:00:00Z"),
      F.label("aiur:in-progress")
    ]

    assert {:ok, [event], _info} = events([F.node(1, %{"timelineItems" => F.timeline(labels)})])
    assert event.fields.in_progress_at == ~U[2026-10-08 10:00:00Z]
    assert length(event.fields.label_events) == 3
  end

  test "complete closed absence differs from open unknown and connected PR fallback" do
    assert {:ok, [event], _info} = events([F.node(1)])
    assert event.fields.merged_at == :none
    assert event.fields.pr_number == :none
    open = F.node(2, %{"state" => "OPEN", "stateReason" => nil, "closedAt" => nil})
    assert {:ok, [event], _info} = events([open])
    assert event.fields.closed_at == :none
    refute Map.has_key?(event.fields, :last_closed_at)
    refute Map.has_key?(event.fields, :merged_at)
    pr = %{"__typename" => "ConnectedEvent", "createdAt" => F.time(), "subject" => %{"number" => 50, "mergedAt" => F.time()}}
    assert {:ok, [event], _info} = events([F.node(3, %{"timelineItems" => F.timeline([pr])})])
    assert event.fields.pr_number == 50
  end

  test "malformed pages reject the entire batch" do
    for body <- [%{}, F.page([nil]), F.page([F.node(1), F.node(0)]), F.page([F.node(1, %{"createdAt" => "bad"})]), F.page([F.node(1, %{"blockedBy" => nil})]), F.page([F.node(1)], true, nil)] do
      assert {:error, :invalid_backfill_page} = BackfillQuery.events(body, @repo, "aiur", @at)
    end

    assert {:error, :invalid_backfill_page} = BackfillQuery.blocked_by_events(%{})
  end
end
