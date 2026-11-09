defmodule AiurWeb.ListenerModeUnknownTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias Aiur.Listener.Effective
  alias AiurWeb.OperatorControlCenter.ListenerMode

  test "a stopped listener renders nil effective mode as Unavailable" do
    listener = Effective.compute(%{requested: :sync, version: 0, actor: :human}, nil)
    assert listener.effective == nil
    assert listener.effective_reason == :not_running
    assert ListenerMode.mode_label(listener.effective) == "Unavailable"
    html = render_component(&ListenerMode.listener_mode/1, listener: listener, now: DateTime.utc_now(), writable: false)
    assert html =~ ~s(data-effective-mode="unavailable")
    assert html =~ "Effective: Unavailable"
    assert html =~ "Agent not running"
  end
end
