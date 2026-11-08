defmodule AiurWeb.Conversation.ComposerTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias AiurWeb.Conversation.Composer

  test "unavailable routing overrides every computed effective mode" do
    for mode <- [:sync, :steer, :async] do
      listener = %{routing: :unavailable, requested: mode, effective: mode}
      html = render_component(&Composer.composer/1, writable: true, target: "42", draft: "", overlay: %{}, listener: listener)
      assert html =~ "Listener unavailable"
      assert html =~ "messages cannot be sent"
      refute html =~ "Steer · interrupts"
      refute html =~ "Sync · next turn"
      refute html =~ "Async · on demand"
    end
  end
end
