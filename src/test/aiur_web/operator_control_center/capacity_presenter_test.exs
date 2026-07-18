defmodule AiurWeb.OperatorControlCenter.CapacityPresenterTest do
  use ExUnit.Case, async: true

  alias AiurWeb.OperatorControlCenter.CapacityPresenter

  test "presents authoritative facts with accessible labels" do
    view =
      CapacityPresenter.present(%{
        active: 3,
        max: 5,
        configured: 5,
        session_override?: false,
        draining?: false
      })

    assert view.available?
    assert view.active == 3
    assert view.max == 5
    assert view.active_label == "3"
    assert view.max_label == "5"
    assert view.source_label == "Configured default"
    assert view.state_label == "Steady"
    assert view.can_decrement?
    assert view.min == 1
    assert view.summary =~ "3 active"
    assert view.summary =~ "maximum 5"
  end

  test "blocks decrement at the minimum of one" do
    view = CapacityPresenter.present(%{active: 1, max: 1, configured: 1, session_override?: false, draining?: false})

    refute view.can_decrement?
  end

  test "labels a session override distinctly from the configured default" do
    view = CapacityPresenter.present(%{active: 2, max: 2, configured: 6, session_override?: true, draining?: false})

    assert view.source_label == "Session override (configured 6)"
    assert view.summary =~ "session override"
  end

  test "names the draining state without relying on colour" do
    view = CapacityPresenter.present(%{active: 6, max: 3, configured: 3, session_override?: true, draining?: true})

    assert view.draining?
    assert view.state_label == "Draining above 3 maximum"
    assert view.summary =~ "draining"
  end

  test "labels absent facts unknown rather than deriving them" do
    for capacity <- [nil, :unavailable, %{}, %{max: 0}, %{max: -1}, %{active: "3", max: nil}] do
      view = CapacityPresenter.present(capacity)

      refute view.available? and is_integer(view.max)
      assert view.max_label == "Unknown"
      refute view.can_decrement?
    end
  end
end
