defmodule AiurWeb.BuildOrderPresenter.EdgesTest do
  use AiurWeb.BuildOrderPresenterCase

  test "classifies all edge states and applies readiness precedence" do
    ready = member(1, state: :closed, state_reason: :completed)
    blocking = member(2)
    terminal = member(3, state: :closed, state_reason: :not_planned)
    unknown = member(4, state: :closed, state_reason: :duplicate)

    target =
      member(5,
        dependencies: [
          Dependency.new(identity(5), identity(1), issue_url(1), :blocked_by),
          Dependency.new(identity(5), identity(2), issue_url(2), :blocked_by),
          Dependency.new(identity(5), identity(3), issue_url(3), :blocked_by),
          Dependency.new(identity(5), identity(4), issue_url(4), :blocked_by)
        ]
      )

    model =
      BuildOrderPresenter.present(
        snapshot([target, unknown, terminal, blocking, ready]),
        status_snapshot(),
        activity_snapshot()
      )

    states = Map.new(model.edges, &{&1.source.identifier, &1.state})

    assert states == %{"1" => :cleared, "2" => :blocking, "3" => :terminal_unsatisfied, "4" => :unknown}
    assert node(model, 5).readiness == :unknown

    without_unknown = snapshot([target_with_blockers(5, [1, 2, 3]), terminal, blocking, ready])

    assert without_unknown |> BuildOrderPresenter.present(status_snapshot(), activity_snapshot()) |> node(5) |> Map.fetch!(:readiness) ==
             :terminal_unsatisfied

    only_blocking = snapshot([target_with_blockers(5, [1, 2]), blocking, ready])

    assert only_blocking |> BuildOrderPresenter.present(status_snapshot(), activity_snapshot()) |> node(5) |> Map.fetch!(:readiness) ==
             :blocking
  end

  test "cycles win over lifecycle and stay scoped to the exact SCC" do
    one = member(1, dependencies: [Dependency.new(identity(1), identity(2), issue_url(2), :blocked_by)])
    two = member(2, dependencies: [Dependency.new(identity(2), identity(1), issue_url(1), :blocked_by)])
    three = member(3, dependencies: [Dependency.new(identity(3), identity(2), issue_url(2), :blocked_by)])
    self = member(4, dependencies: [Dependency.new(identity(4), identity(4), issue_url(4), :blocked_by)])

    model = BuildOrderPresenter.present(snapshot([three, self, two, one]), status_snapshot(), activity_snapshot())

    assert Enum.map(model.edges, &{{&1.source.identifier, &1.target.identifier}, &1.state}) == [
             {{"1", "2"}, :cyclic},
             {{"2", "1"}, :cyclic},
             {{"2", "3"}, :blocking},
             {{"4", "4"}, :cyclic}
           ]

    assert node(model, 1).readiness == :cyclic
    assert node(model, 2).readiness == :cyclic
    assert node(model, 3).readiness == :blocking
    assert node(model, 4).readiness == :cyclic
  end

  test "keeps external and missing endpoints explicit, nonjoinable, and safe" do
    foreign = identity(9, "FOREIGN-9", {"other", "repo"})

    target =
      member(1,
        dependencies: [
          Dependency.new(identity(1), foreign, "https://github.com/other/repo/issues/9", :blocked_by),
          Dependency.new(identity(1), identity(8), issue_url(8), :blocked_by),
          Dependency.new(identity(1), nil, "https://github.com/owner/repo/issues/7", :blocked_by)
        ]
      )

    model = BuildOrderPresenter.present(snapshot([target]), status_snapshot(), activity_snapshot())

    assert Enum.map(model.edges, & &1.kind) == [:external, :native, :unknown]
    assert Enum.all?(model.edges, &(&1.state == :unknown))
    assert node(model, 1).readiness == :unknown
    assert :external_dependency in diagnostic_codes(model)
    refute :unresolved_internal_dependency in diagnostic_codes(model)
    assert model.adjacency[key(1)] == []

    external = Enum.find(model.edges, &(&1.kind == :external))
    assert external.url == "https://github.com/other/repo/issues/9"

    relationships = BuildOrderPresenter.relationships(model, identity(1))
    assert relationships.external == Enum.filter(relationships.blocked_by, &(&1.kind != :native))
  end

  test "a same-repository blocker outside the root is a cross-root edge, not a missing dependency" do
    # #1777 made this ordinary; #1872 removes the false "configured-repository
    # dependency is missing from this graph" warning it used to surface.
    target = member(1, dependencies: [Dependency.new(identity(1), identity(8), issue_url(8), :blocked_by)])

    model = BuildOrderPresenter.present(snapshot([target]), status_snapshot(), activity_snapshot())

    assert [edge] = model.edges
    assert edge.kind == :native
    assert edge.state == :unknown
    refute :unresolved_internal_dependency in diagnostic_codes(model)
  end

  test "same issue number in another repository never joins runtime facts" do
    ticket = member(42)
    foreign_same_number = identity(42, "FOREIGN", {"other", "repo"})

    execution = %{
      running: [%{tracker_identity: foreign_same_number, work_state: :working}],
      retrying: [],
      idle: []
    }

    activity = activity_snapshot([activity(foreign_same_number, 99, :review)])
    model = BuildOrderPresenter.present(snapshot([ticket]), execution, activity)

    assert node(model, 42).execution.status == :unknown
    assert node(model, 42).activity.status == :unknown
    assert node(model, 42).card.progress == :unknown
  end

  test "duplicate exact runtime identities fail only that subrecord closed" do
    ticket = member(1)
    execution_row = %{tracker_identity: identity(1), work_state: :working}
    activity_row = activity(identity(1), 70, :review)

    model =
      BuildOrderPresenter.present(
        snapshot([ticket]),
        %{running: [execution_row], retrying: [execution_row], idle: []},
        activity_snapshot([activity_row, activity_row])
      )

    assert node(model, 1).plan.lifecycle.state == :open
    assert node(model, 1).execution.status == :unknown
    assert node(model, 1).activity.status == :unknown
    assert node(model, 1).health.execution == :ambiguous
    assert node(model, 1).health.activity == :ambiguous
    assert :duplicate_identity in diagnostic_codes(model)
  end

  test "preserves metadata warnings and deterministic fallback groups" do
    ungrouped = Member.new(%{identity: identity(1), title: "Ungrouped", url: issue_url(1), state: :open, state_reason: nil})
    grouped = member(2, lane: "runtime", phase: 3)

    first = BuildOrderPresenter.present(snapshot([grouped, ungrouped]), status_snapshot(), activity_snapshot())
    second = BuildOrderPresenter.present(snapshot([ungrouped, grouped]), status_snapshot(), activity_snapshot())

    assert first == second
    assert Enum.map(first.lane_groups, &{&1.key, &1.label}) == [{"runtime", "Runtime"}, {:unassigned, "Unassigned"}]
    assert Enum.map(first.phase_groups, &{&1.key, &1.label}) == [{3, "Wave 3"}, {:unphased, "Unphased"}]
    assert :missing_lane in Enum.map(node(first, 1).diagnostics, & &1.code)
    assert :missing_phase in Enum.map(node(first, 1).diagnostics, & &1.code)
  end
end
