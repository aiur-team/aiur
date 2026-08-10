defmodule AiurWeb.OperatorControlCenter.UnitsPolicyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AiurWeb.OperatorControlCenter.UnitsPolicy

  test "scopes Live, Unfinished, All, and None before applying conditions" do
    rows = [active_row(), queued_row(), finished_row(), unknown_row()]

    assert UnitsPolicy.filter(rows, %{scope: :live, conditions: MapSet.new()}) == [active_row()]
    assert UnitsPolicy.filter(rows, %{scope: :unfinished, conditions: MapSet.new()}) == [active_row(), queued_row()]
    assert UnitsPolicy.filter(rows, %{scope: :all, conditions: MapSet.new()}) == rows
    assert UnitsPolicy.filter(rows, %{scope: :none, conditions: MapSet.new()}) == []
  end

  test "normalized selections expose scope and condition membership through policy accessors" do
    selection = UnitsPolicy.normalize_selection(%{scope: :unfinished, conditions: [:active, :paused]})

    assert UnitsPolicy.scope(selection) == :unfinished
    assert UnitsPolicy.selected?(selection, :active)
    assert UnitsPolicy.selected?(selection, :paused)
    refute UnitsPolicy.selected?(selection, :queued)
  end

  test "conditions overlap and chip counts are calculated before OR refinement" do
    alert_paused =
      active_row(
        reasons: %{alert: :open_command, pause: :executor},
        runtime: %{bucket: :running, work_state: :paused}
      )

    alert_stuck =
      active_row(
        reasons: %{alert: :open_command, stuck: :unresponsive},
        runtime: %{bucket: :running, work_state: :working, waiting_reason: :unresponsive}
      )

    dependency_waiting = queued_row(reasons: %{waiting: :waiting_for_dependency, blocking: :waiting_for_dependency})
    rows = [alert_paused, alert_stuck, dependency_waiting, finished_row()]
    selection = %{scope: :all, conditions: MapSet.new([:alert, :paused])}

    assert UnitsPolicy.filter(rows, selection) == [alert_paused, alert_stuck]

    assert UnitsPolicy.counts(rows, selection) == %{
             scope: 4,
             active: 1,
             alert: 2,
             paused: 1,
             stuck: 1,
             queued: 1,
             finished: 1
           }

    assert UnitsPolicy.condition?(:queued, dependency_waiting)
    assert UnitsPolicy.condition?(:stuck, alert_stuck)
  end

  test "the completed awaiting-dispatch replacement boundary is queued and unfinished only" do
    replacement = %{
      lifecycle: :waiting,
      terminal?: false,
      replacement_boundary?: true,
      runtime: %{bucket: :running, work_state: :completed, waiting_reason: :awaiting_dispatch, tracker_paused?: true},
      reasons: %{waiting: :awaiting_dispatch},
      open_command_count: 0
    }

    assert UnitsPolicy.in_scope?(replacement, :unfinished)
    refute UnitsPolicy.in_scope?(replacement, :live)
    assert UnitsPolicy.condition?(:queued, replacement)
    refute UnitsPolicy.condition?(:active, replacement)
    refute UnitsPolicy.condition?(:paused, replacement)
    refute UnitsPolicy.condition?(:finished, replacement)
  end

  test "terminal rows with stale activity remain Finished without becoming Stuck" do
    row = finished_row(%{latest_evidence: %{status: :known, freshness: :stale}})

    assert UnitsPolicy.condition?(:finished, row)
    refute UnitsPolicy.condition?(:stuck, row)
    refute UnitsPolicy.in_scope?(row, :unfinished)
  end

  test "tracker-unavailable rows remain visible as queued and stuck" do
    row =
      queued_row(
        runtime: %{bucket: :idle, work_state: :idle, waiting_reason: :tracker_unavailable},
        reasons: %{waiting: :tracker_unavailable, stuck: :tracker_unavailable}
      )

    assert UnitsPolicy.in_scope?(row, :unfinished)
    assert UnitsPolicy.condition?(:queued, row)
    assert UnitsPolicy.condition?(:stuck, row)
  end

  property "single-condition filtering and counts share the same predicate" do
    rows = [active_row(), queued_row(), finished_row(), unknown_row()]

    check all(
            scope <- member_of(UnitsPolicy.scopes()),
            condition <- member_of(UnitsPolicy.conditions()),
            max_runs: 20
          ) do
      selection = %{scope: scope, conditions: MapSet.new([condition])}
      counts = UnitsPolicy.counts(rows, selection)

      assert length(UnitsPolicy.filter(rows, selection)) == Map.fetch!(counts, condition)
    end
  end

  property "multiple selected conditions retain every scoped row matching any selected predicate" do
    rows = [active_row(), queued_row(), finished_row(), unknown_row()]

    check all(
            scope <- member_of(UnitsPolicy.scopes()),
            conditions <- list_of(member_of(UnitsPolicy.conditions()), max_length: 6),
            max_runs: 20
          ) do
      selection = %{scope: scope, conditions: MapSet.new(conditions)}

      expected =
        UnitsPolicy.rows_for_scope(rows, selection)
        |> Enum.filter(fn row -> conditions == [] or Enum.any?(conditions, &UnitsPolicy.condition?(&1, row)) end)

      assert UnitsPolicy.filter(rows, selection) == expected
    end
  end

  defp active_row(attrs \\ %{}) do
    Map.merge(
      %{
        lifecycle: :running,
        terminal?: false,
        replacement_boundary?: false,
        runtime: %{bucket: :running, work_state: :working, waiting_reason: :active},
        reasons: %{},
        open_command_count: 0
      },
      Map.new(attrs)
    )
  end

  defp queued_row(attrs \\ %{}) do
    Map.merge(
      %{
        lifecycle: :queued,
        terminal?: false,
        replacement_boundary?: false,
        runtime: %{bucket: :idle, work_state: nil, waiting_reason: :waiting_for_dependency},
        reasons: %{waiting: :waiting_for_dependency},
        open_command_count: 0
      },
      Map.new(attrs)
    )
  end

  defp finished_row(attrs \\ %{}) do
    Map.merge(
      %{
        lifecycle: :completed,
        terminal?: true,
        replacement_boundary?: false,
        runtime: %{bucket: nil, work_state: nil, waiting_reason: nil},
        reasons: %{},
        open_command_count: 0
      },
      Map.new(attrs)
    )
  end

  defp unknown_row do
    %{
      lifecycle: nil,
      terminal?: false,
      replacement_boundary?: false,
      runtime: %{bucket: nil, work_state: nil, waiting_reason: nil},
      reasons: %{},
      open_command_count: nil
    }
  end
end
