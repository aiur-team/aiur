defmodule Aiur.BuildOrder.Features.LabelRulesTest do
  use ExUnit.Case, async: true
  alias Aiur.BuildOrder.Features.LabelRules, as: Rules
  @t ~U[2026-10-09 12:00:00Z]

  defp row(overrides \\ %{}),
    do:
      Map.merge(
        %{number: 12, labels: [], labels_complete: true, label_events: [], observed_at: DateTime.add(@t, 130), registered_slugs: MapSet.new(["auth", "other"]), health: %{state: :healthy}},
        overrides
      )

  defp owner(extra \\ %{}), do: Map.merge(%{feature: "auth", source: "cli:x", confirmed: true}, extra)
  defp entries(state \\ :labelled), do: %{{"auth", 12} => %{Rules.entry(state, @t) | written_at: @t, seen_at: @t}}

  test "validates and normalizes feature slugs" do
    assert Rules.parse("FEATURE:Auth-2") == {:ok, "auth-2"}
    for label <- ["feature:", "feature:-bad", "feature:a/b", "feature:" <> String.duplicate("a", 43), "agent:todo", nil], do: assert(Rules.parse(label) == :ignore)
  end

  test "unknown labels and unhealthy observations never remove membership" do
    assert Rules.decide(row(%{labels: :unknown}), owner(), entries(), @t) == []

    for health <- [:stale, :unavailable, :structurally_invalid] do
      assert Rules.decide(row(%{health: %{state: health}}), owner(), entries(), @t) == []
    end
  end

  test "truncated or unknown completeness never proves absence" do
    for completeness <- [false, :unknown], do: assert(Rules.decide(row(%{labels_complete: completeness}), owner(), entries(), @t) == [])
  end

  test "label joins retain the newest event actor and time" do
    event = %{label: "feature:auth", action: :labeled, at: @t, actor: "kev"}
    assert [{:add, "auth", [12], meta}] = Rules.decide(row(%{labels: ["feature:auth"], label_events: [event]}), nil, %{}, @t)
    assert meta == [source: "label:kev", actor: "kev", at: @t]
  end

  test "absent, unknown and invalid actors stay unknown" do
    for events <- [[], :unknown, [%{label: "feature:auth", action: :labeled, at: @t, actor: "bad/login"}]] do
      r = row(%{labels: ["feature:auth"], label_events: events})
      assert [{:add, "auth", [12], meta}] = Rules.decide(r, nil, %{}, @t)
      assert meta[:source] == "label:unknown"
      assert meta[:actor] == "unknown"
      assert meta[:at] == if(is_list(events) and events != [], do: @t, else: r.observed_at)
    end
  end

  test "unregistered labels never create features; multiple registered labels conflict" do
    assert Rules.decide(row(%{labels: ["feature:zzz"]}), nil, %{}, @t) == [{:unregistered, 12, "zzz"}]
    assert Rules.decide(row(%{labels: ["feature:auth", "feature:other"]}), nil, %{}, @t) == [{:conflict, 12, ["auth", "other"]}]
  end

  test "confirmed ownership wins over a human label for another feature" do
    assert Rules.decide(row(%{labels: ["feature:other"]}), owner(), entries(:pending_label), @t) == [{:conflict, 12, ["auth", "other"]}]
  end

  test "a human label moves an unconfirmed backfill guess" do
    o = owner(%{source: "backfill-agent", confirmed: false})
    assert [{:add, "other", [12], meta}] = Rules.decide(row(%{labels: ["feature:other"]}), o, entries(:held_backfill), @t)
    assert meta[:move] == true
    assert meta[:source] == "label:unknown"
  end

  test "pending deletion and settled tombstones block rejoining" do
    for state <- [:pending_unlabel, :unlabelled], do: assert(Rules.decide(row(%{labels: ["feature:auth"]}), nil, entries(state), @t) == [])
  end

  test "absence waits inside settle; a newer observation after settle leaves" do
    assert Rules.decide(row(%{observed_at: DateTime.add(@t, 30)}), owner(), entries(), @t) == [{:recheck, DateTime.add(@t, 120_000, :millisecond), 12}]
    assert [{:remove, "auth", [12], meta}] = Rules.decide(row(), owner(), entries(), DateTime.add(@t, 130))
    assert meta[:source] == "label:unknown"
    assert meta[:at] == DateTime.add(@t, 130)
    # A timer never makes an old observation fresh enough to remove membership.
    assert Rules.decide(row(%{observed_at: DateTime.add(@t, 30)}), owner(), entries(), DateTime.add(@t, 130)) == []
  end

  test "label-origin membership settles against seen_at without written_at" do
    e = put_in(entries()[{"auth", 12}].written_at, nil)
    assert [{:remove, "auth", [12], _}] = Rules.decide(row(), owner(), e, DateTime.add(@t, 130))
  end

  test "echo marks pending entries labelled, but never releases exempt or held joins" do
    r = row(%{labels: ["feature:auth"]})

    for state <- [:pending_label, :labelled, :failed] do
      assert [{:put, {"auth", 12}, next}] = Rules.decide(r, owner(), entries(state), @t)
      assert next.state == :labelled
      assert next.seen_at == r.observed_at
    end

    for state <- [:exempt, :held_backfill], do: assert(Rules.decide(r, owner(), entries(state), @t) == [])
  end

  test "expected absences do nothing; absent pending deletion becomes unlabelled" do
    for state <- [:pending_label, :exempt, :held_backfill], do: assert(Rules.decide(row(), owner(), entries(state), @t) == [])
    assert [{:put, {"auth", 12}, next}] = Rules.decide(row(), nil, entries(:pending_unlabel), @t)
    assert next.state == :unlabelled
  end

  test "registry sources select their start states" do
    owners =
      for {n, source, confirmed} <- [
            {1, "cli:x", true},
            {2, "agent:2", true},
            {3, "label:kev", true},
            {4, "import:build-order", true},
            {5, "backfill-agent", false},
            {6, "agent:6", false},
            {7, "inherited:parent", true}
          ],
          into: %{},
          do: {n, owner(%{source: source, confirmed: confirmed})}

    e = Rules.reconcile_registry(%{}, owners, @t)
    assert for(n <- 1..7, do: e[{"auth", n}].state) == [:pending_label, :pending_label, :labelled, :exempt, :held_backfill, :exempt, :pending_label]
    assert e[{"auth", 3}].seen_at == @t
  end

  test "moves leave deletion tombstones; exempt and held removals disappear" do
    e = Rules.reconcile_registry(entries(), %{12 => owner(%{feature: "other"})}, @t)
    assert e[{"auth", 12}].state == :pending_unlabel
    assert e[{"other", 12}].state == :pending_label
    for state <- [:held_backfill, :exempt], do: assert(Rules.reconcile_registry(entries(state), %{}, @t) == %{})
    assert Rules.reconcile_registry(entries(:unlabelled), %{}, DateTime.add(@t, 86_401)) == %{}
  end

  test "explicit rejoin resets a tombstone; failed deletion remains failed" do
    assert Rules.reconcile_registry(entries(:unlabelled), %{12 => owner()}, @t)[{"auth", 12}].state == :pending_label
    e = put_in(entries(:failed)[{"auth", 12}].failed_from, :pending_unlabel)
    assert Rules.reconcile_registry(e, %{}, @t)[{"auth", 12}].state == :failed
  end
end
