defmodule VoiceConverse.EventsTest do
  use ExUnit.Case, async: true

  alias VoiceConverse.Events

  # Regression guard (labelled): the event set must stay equal to voice-session contract §4.1.
  test "the event modules match the contract §4.1 list" do
    assert Events.all() == [
             Events.UserTranscript,
             Events.AgentText,
             Events.AgentAudio,
             Events.Interruption,
             Events.ToolCall,
             Events.ProviderConversationId,
             Events.Closed,
             Events.Error
           ]
  end

  test "an event cannot be built without its contract fields" do
    assert_raise ArgumentError, fn -> struct!(Events.AgentAudio, turn_id: "t1", data_b64: "AA") end
    assert_raise ArgumentError, fn -> struct!(Events.UserTranscript, text: "hi") end
  end

  test "an unclassified failure is provider_error, never a guessed auth or quota code" do
    assert %Events.Error{code: :provider_error} = Events.Error.new(:rate_limited, "slow down")
    assert %Events.Error{code: :provider_error} = Events.Error.new(429, "slow down")
    assert %Events.Error{code: :provider_quota} = Events.Error.new(:provider_quota, "quota")
  end

  test "a raw provider frame never becomes the operator message" do
    raw = %{"type" => "error", "detail" => "xi-secret"}
    error = Events.Error.new(:provider_auth, raw)
    assert error.code == :provider_auth
    assert error.message == "provider error"
    refute inspect(error) =~ "xi-secret"
  end

  test "event?/1 accepts only normalized event structs" do
    assert Events.event?(%Events.Closed{reason: :normal})
    refute Events.event?(%URI{})
    refute Events.event?(%{type: "agent_response"})
  end
end
