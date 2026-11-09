defmodule Aiur.VoiceConversation.SessionFinishTest do
  use ExUnit.Case, async: true

  alias Aiur.VoiceConversation.Session

  test "handoff failure remains visible instead of producing a receipt" do
    state = %{owner: self(), id: "failed-session", turns: [], pending_user: nil, deliver: fn _, _, _ -> {:error, :disk_full} end}
    assert {:stop, :normal, ^state} = Session.handle_info({:voice_conversation, state.id, {:ended, :user_end}}, state)
    assert_received {:executor_voice, {:handoff_failed, :delivery_failed}}
    assert_received {:executor_voice, {:ended, :user_end}}
    refute_received {:executor_voice, {:receipt, _}}
  end
end
