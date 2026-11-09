defmodule AiurWeb.StreamdeckOverrideStatusTest do
  use ExUnit.Case, async: true
  alias AiurWeb.StreamdeckCommands
  alias AiurWeb.StreamdeckLive.CommandKeys

  test "queued and delivered overrides reach the existing history keys and detail strip" do
    for {state, label} <- [{:queued, "override queued"}, {:delivered, "override delivered"}, {:failed, "override failed"}] do
      command =
        StreamdeckCommands.item(
          struct(Aiur.Decision, %{decision_id: "deck-override", created_at: DateTime.utc_now(), context: %{}, options: [], ticket: %{}, decision_status: :decided, overrides: [%{state: state}]})
        )

      assert command["override_status"] == label
      [key | _] = CommandKeys.commands_history_keys(%{"items" => [command]}, nil)
      assert key.status == label
      panel = CommandKeys.commands_panel(%{commands_view: :detail, commands_selection: command, commands_offset: 0, commands_option: nil})
      assert panel.status == label
    end
  end
end
