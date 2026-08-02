defmodule AiurWeb.OperatorControlCenter.NavStateTest do
  use ExUnit.Case, async: true

  alias AiurWeb.OperatorControlCenter.NavState
  alias Phoenix.LiveView.Socket

  defp socket(assigns \\ %{}) do
    %Socket{assigns: Map.merge(%{__changed__: %{}}, assigns)}
  end

  test "defaults to expanded and survives being seeded twice" do
    socket = socket() |> NavState.assign_nav()
    refute NavState.collapsed?(socket)

    # A remount/patch must not silently expand a collapsed sidebar back open —
    # that reversion is the #1306 bug in assign form.
    collapsed = NavState.toggle(socket)
    assert NavState.collapsed?(NavState.assign_nav(collapsed))
  end

  test "toggle flips the collapsed state in both directions" do
    socket = socket() |> NavState.assign_nav()

    collapsed = NavState.toggle(socket)
    assert NavState.collapsed?(collapsed)

    expanded = NavState.toggle(collapsed)
    refute NavState.collapsed?(expanded)
  end

  test "restore applies a client-supplied boolean verbatim" do
    socket = socket() |> NavState.assign_nav()

    assert NavState.collapsed?(NavState.restore(socket, true))
    refute NavState.collapsed?(NavState.restore(NavState.toggle(socket), false))
  end

  test "restore ignores non-boolean values rather than raising" do
    collapsed = socket() |> NavState.assign_nav() |> NavState.toggle()

    # A corrupt or absent localStorage value must not crash the LiveView or
    # silently flip the sidebar; it degrades to the state already held.
    for bad <- ["true", nil, 1, %{}] do
      assert NavState.collapsed?(NavState.restore(collapsed, bad)),
             "restore/2 changed state for #{inspect(bad)}"
    end
  end
end
