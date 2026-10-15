defmodule AiurWeb.OperatorControlCenter.UnitsPresenterSelectionTest do
  use ExUnit.Case, async: true

  alias AiurWeb.OperatorControlCenter.{UnitsPresenter, UnitsURL}

  import AiurWeb.OperatorControlCenter.UnitsPresenterFixtures

  test "selection helpers validate scopes and independently toggle conditions" do
    selection = UnitsURL.default_selection()

    selection = UnitsPresenter.select_scope(selection, "all")
    assert selection.scope == :all

    selection = UnitsPresenter.toggle_condition(selection, "paused")
    selection = UnitsPresenter.toggle_condition(selection, :alert)
    assert selection.conditions == [:alert, :paused]

    assert UnitsPresenter.toggle_condition(selection, "unknown") == selection
    assert UnitsPresenter.toggle_condition(selection, :paused).conditions == [:alert]
    assert UnitsPresenter.select_scope(selection, "invalid").scope == :live
  end

  test "bulk filter actions select every visible prior filter or none" do
    assert UnitsPresenter.select_all_filters() == %{
             scope: :unfinished,
             conditions: [:active, :alert, :paused, :queued, :finished]
           }

    assert UnitsPresenter.select_no_filters() == %{scope: :none, conditions: []}
  end

  test "row tokens are stable opaque server lookup keys" do
    alpha = identity("NODE-alpha-private", "41")
    catalog = UnitsPresenter.load(payload(alpha), membership_fun: fn -> membership([member(alpha)]) end, activity_fun: fn -> %{entries: []} end)
    [row] = catalog.snapshot.rows

    token = UnitsPresenter.row_token(row)

    assert is_binary(token)
    refute String.contains?(token, "NODE-alpha-private")
    assert {:ok, ^row} = UnitsPresenter.lookup(catalog, token)
    assert {:error, :not_found} = UnitsPresenter.lookup(catalog, token <> "changed")
  end
end
