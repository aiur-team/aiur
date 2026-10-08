defmodule Aiur.BuildOrder.History.FeedTest do
  use ExUnit.Case, async: true
  alias Aiur.BuildOrder.History.{Feed, Row, TelemetryScan}
  alias Aiur.BuildOrder.Lifecycle
  @t ~U[2026-10-01 12:00:00Z]
  @later ~U[2026-10-01 12:01:00Z]

  defp body(extra \\ %{}), do: Map.merge(%{"number" => 7, "title" => "Issue", "state" => "open", "updated_at" => DateTime.to_iso8601(@t), "labels" => [%{"name" => "Agent:Done"}]}, extra)

  defp apply_event(row, event) do
    case Row.merge(row, event) do
      {:changed, row} -> row
      :unchanged -> row
    end
  end

  test "normalizes bodies and records label differences only after first sighting" do
    [first] = Feed.issue(nil, body(), @t)
    row = apply_event(nil, first)
    assert row.labels == ["agent:done"]
    assert row.closed_at == :none
    assert row.label_events == :unknown
    [changed] = Feed.issue(row, body(%{"labels" => ["AGENT:TODO"], "updated_at" => DateTime.to_iso8601(@later)}), @later)
    assert changed.fields.label_events == [%{label: "agent:todo", action: :labeled, at: @later, actor: :unknown}, %{label: "agent:done", action: :unlabeled, at: @later, actor: :unknown}]
    assert Feed.issue(nil, %{"number" => "bad"}, @t) == []
    assert Feed.issue(nil, body(%{"updated_at" => "bad"}), @t) |> hd() |> Map.fetch!(:fields) |> Map.has_key?(:updated_at) == false
  end

  test "late body cannot close a newer reopened row (store regression guard)" do
    row = %Row{number: 7, lifecycle: %Lifecycle{state: :open, state_reason: :reopened}, updated_at: @later, observed_at: @later, closed_at: :none}
    [event] = Feed.issue(row, body(%{"state" => "closed", "state_reason" => "completed"}), @later)
    assert apply_event(row, event).lifecycle.state == :open
  end

  test "absence closes with unknown time and a later listing reopens it" do
    row = %Row{number: 7, lifecycle: %Lifecycle{state: :open, state_reason: :none}, observed_at: @t, updated_at: @t, closed_at: :none}
    [absent] = Feed.listing(%{7 => row}, [], @later)
    closed = apply_event(row, absent)
    assert closed.lifecycle == %Lifecycle{state: :closed, state_reason: :unknown}
    assert closed.closed_at == :unknown
    issue = %Aiur.Issue{id: "7", title: "reopened", created_at: @t, updated_at: @t, labels: []}
    [open] = Feed.listing(%{7 => closed}, [issue], DateTime.add(@later, 1))
    reopened = apply_event(closed, open)
    assert reopened.lifecycle.state == :open
    assert reopened.closed_at == :none
  end

  test "listing timestamp protects a newer deposited close and open" do
    row = %Row{number: 7, lifecycle: %Lifecycle{state: :open, state_reason: :none}, observed_at: @later, updated_at: @later}
    [event] = Feed.listing(%{7 => row}, [], @t)
    assert apply_event(row, event).lifecycle.state == :open
    closed = %{row | lifecycle: %Lifecycle{state: :closed, state_reason: :completed}}
    issue = %Aiur.Issue{id: "7", title: "old", labels: [], updated_at: @t}
    [event] = Feed.listing(%{7 => closed}, [issue], @t)
    assert apply_event(closed, event).lifecycle.state == :closed
  end

  test "edges preserve unknown sets and remove only the matching parent" do
    body = %{"blocked_issue_number" => 7, "blocking_issue_number" => 2, "present" => true}
    assert Feed.dependency(%Row{}, body, "acme/widgets", @t, :webhook) == []
    [add] = Feed.dependency(%Row{blocked_by: []}, body, "acme/widgets", @t, :webhook)
    assert add.fields.blocked_by == [Feed.ref("acme/widgets", 2)]
    [remove] = Feed.dependency(%Row{blocked_by: add.fields.blocked_by}, %{body | "present" => false}, "acme/widgets", @later, :webhook)
    assert remove.fields.blocked_by == []
    sub = %{"parent_issue_number" => 1, "sub_issue_number" => 7, "present" => true}
    [child, root] = Feed.sub_issue(nil, sub, "acme/widgets", @t, :webhook)
    assert child.fields.parent == Feed.ref("acme/widgets", 1)
    assert root.fields.sub_issues_added == [%{ref: Feed.ref("acme/widgets", 7), at: @t}]
    [removed] = Feed.sub_issue(%Row{parent: child.fields.parent}, %{sub | "present" => false}, "acme/widgets", @later, :webhook)
    assert removed.fields.parent == :none
    assert Feed.sub_issue(%Row{parent: :none}, %{sub | "present" => false}, "acme/widgets", @later, :webhook) == []
  end

  test "independent blocker deltas do not advance the full-set cutoff" do
    held = %Row{number: 7, blocked_by: [], observed_at: @t, sources: [:backfill]}
    newer = %{"blocked_issue_number" => 7, "blocking_issue_number" => 3, "present" => true, "edge_version" => DateTime.to_iso8601(@later)}
    older = %{newer | "blocking_issue_number" => 2, "edge_version" => DateTime.to_iso8601(@t)}
    [first] = Feed.dependency(held, newer, "acme/widgets", @later, :webhook)
    held = apply_event(held, first)
    [second] = Feed.dependency(held, older, "acme/widgets", @later, :webhook)
    assert MapSet.new(second.fields.blocked_by) == MapSet.new([Feed.ref("acme/widgets", 2), Feed.ref("acme/widgets", 3)])
    assert held.blocked_by_version == DateTime.to_iso8601(@t)
  end

  test "in-flight catch-up cannot replace a newer edge observation" do
    row = %Row{number: 7, parent: :none, parent_version: DateTime.to_iso8601(@later), blocked_by: [], blocked_by_version: DateTime.to_iso8601(@later)}

    event =
      Feed.event(
        7,
        %{parent: Feed.ref("acme/widgets", 1), parent_version: DateTime.to_iso8601(@t), blocked_by: [Feed.ref("acme/widgets", 2)], blocked_by_version: DateTime.to_iso8601(@t)},
        @t,
        :catch_up
      )

    protected = Feed.protect_edges(row, event)
    refute Map.has_key?(protected.fields, :parent)
    refute Map.has_key?(protected.fields, :blocked_by)
    assert Feed.protect_edges(nil, event) == event
  end

  test "merges filter repositories and keep the latest PR" do
    merge = %{repository: "ACME/Widgets", ticket_id: "7", merged_at: @later, number: 8}
    [event] = Feed.merge(%Row{merged_at: @t}, merge, "acme/widgets", @later)
    assert event.fields == %{merged_at: @later, pr_number: 8}
    assert Feed.merge(%Row{merged_at: @later}, merge, "acme/widgets", @later) == []
    assert Feed.merge(nil, merge, "other/repo", @later) == []
  end

  test "boot telemetry streams earliest dispatch points and skips corrupt records" do
    path = Path.join(System.tmp_dir!(), "dispatch-#{System.unique_integer([:positive])}.ndjson")
    on_exit(fn -> File.rm(path) end)

    lines =
      for {boundary, at} <- [{"point", @later}, {"point", @t}, {"open", DateTime.add(@t, -60)}],
          do: Jason.encode!(%{timestamp: DateTime.to_iso8601(at), attributes: %{event: "dispatch", boundary: boundary, ticket: "7"}})

    File.write!(path, Enum.join(["bad dispatch" | lines], "\n"))
    assert TelemetryScan.dispatches(path) == %{7 => @t}
    assert TelemetryScan.dispatches(path <> ".missing") == %{}
    File.write!(path, Jason.encode!(%{timestamp: "bad", attributes: %{event: "dispatch", boundary: "point", ticket: "7"}}))
    assert TelemetryScan.dispatches(path) == %{}
  end
end
