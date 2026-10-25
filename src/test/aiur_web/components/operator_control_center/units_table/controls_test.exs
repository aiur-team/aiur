defmodule AiurWeb.OperatorControlCenter.UnitsTableControlsTest do
  use ExUnit.Case, async: true

  alias AiurWeb.OperatorControlCenter.UnitsPresenter

  import AiurWeb.OperatorControlCenter.UnitsTableFixtures

  test "renders a named, reachable pause control for a running unit when writable" do
    row = row()
    token = UnitsPresenter.row_token(row)
    html = render_controls([row], %{}, true)

    assert html =~ ~s(id="units-control-#{token}")
    assert html =~ ~s(phx-click="request-unit-control")
    assert html =~ ~s(phx-value-unit="#{token}")
    assert html =~ ~s(phx-value-action="pause")
    assert html =~ ~s(aria-label="Pause acme/aiur #1110")
    assert html =~ "units-control-action"
    assert html =~ ~s(title="Pause")
    assert html =~ ~s(aria-disabled="false")
  end

  test "renders the selected account on a unit row" do
    html = render(view([Map.put(row(), :account, "max")]))
    assert html =~ ~s(class="u-pill u-account">max</span>)
  end

  test "renders resume for an applied-paused unit" do
    row = put_in(row(), [:runtime, :work_state], :paused)
    html = render_controls([row], %{}, true)

    assert html =~ ~s(phx-value-action="resume")
    assert html =~ ~s(title="Resume")
    assert html =~ "is-resume"
  end

  test "disables the control and marks read-only when the dashboard is not writable" do
    row = row()
    html = render_controls([row], %{}, false)

    assert html =~ ~s(disabled)
    assert html =~ ~s(aria-disabled="true")
  end

  test "renders a disabled control with a reason for a terminal unit" do
    row = Map.put(row(), :terminal?, true)
    html = render_controls([row], %{}, true)

    assert html =~ "units-control-disabled"
    assert html =~ "Control unavailable"
    refute html =~ ~s(phx-click="request-unit-control")
  end

  test "mirrors applied evidence only from lifecycle state, with an aria-live status" do
    row = put_in(row(), [:runtime, :work_state], :paused)
    token = UnitsPresenter.row_token(row)
    controls = %{token => %{action: :pause, status: :applied, identifier: "1110"}}
    html = render_controls([row], controls, true)

    assert html =~ "units-control-status"
    assert html =~ ~s(aria-live="polite")
    assert html =~ "tone-applied"
    assert html =~ "Paused"
  end

  test "surfaces a retryable rejection distinctly from success" do
    row = row()
    token = UnitsPresenter.row_token(row)
    controls = %{token => %{action: :pause, status: :rejected, rejection: %{class: :control_failed}, identifier: "1110"}}
    html = render_controls([row], controls, true)

    assert html =~ "tone-error"
    assert html =~ "retry"
    refute html =~ "tone-applied"
  end

  test "request-only never masquerades as an applied control" do
    row = row()
    token = UnitsPresenter.row_token(row)
    controls = %{token => %{action: :pause, status: :request_only, identifier: "1110"}}
    html = render_controls([row], controls, true)

    assert html =~ "tone-warning"
    assert html =~ "request-only"
    refute html =~ "tone-applied"
  end
end
