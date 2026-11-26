defmodule VoiceConverse.SessionLookupTest do
  use ExUnit.Case, async: true

  test "all transport operations return the documented error when a session is absent" do
    instance = Module.concat(__MODULE__, "Instance#{System.unique_integer([:positive])}")
    start_supervised!({Registry, keys: :unique, name: VoiceConverse.SessionRegistry.name(instance)})

    operations = [
      fn -> VoiceConverse.push_audio(instance, "missing", "AAAA") end,
      fn -> VoiceConverse.push_text(instance, "missing", "hello") end,
      fn -> VoiceConverse.playback_state(instance, "missing", "playing") end,
      fn -> VoiceConverse.end_session(instance, "missing") end,
      fn -> VoiceConverse.confirm_draft(instance, "missing", "draft", origin: :client) end,
      fn -> VoiceConverse.discard_draft(instance, "missing", "draft", origin: :client) end,
      fn -> VoiceConverse.subscribe(instance, "missing", self()) end,
      fn -> VoiceConverse.unsubscribe(instance, "missing", self()) end
    ]

    for operation <- operations, do: assert(operation.() == {:error, :not_found})
  end
end
