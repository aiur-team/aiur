defmodule AiurWeb.VoiceReasonCodeTest do
  use ExUnit.Case, async: true

  alias AiurWeb.VoiceReasonCode

  test "a provider error keeps the code the provider adapter carried" do
    assert VoiceReasonCode.provider(%{code: :provider_auth, message: "anything"}) == "provider_auth"
    assert VoiceReasonCode.provider(%{code: :provider_quota, message: "anything"}) == "provider_quota"
    # The adapter judged this one unclassified; a familiar text must not upgrade it.
    assert VoiceReasonCode.provider(%{code: :provider_error, message: "ElevenLabs rate limit reached"}) == "provider_error"
  end

  test "bare provider text falls back to the named causes only" do
    assert VoiceReasonCode.provider("ElevenLabs rejected the API key") == "provider_auth"
    assert VoiceReasonCode.provider("ElevenLabs quota exhausted") == "provider_quota"
    assert VoiceReasonCode.provider("ElevenLabs rate limit reached") == "provider_quota"
    assert VoiceReasonCode.provider("ElevenLabs terms not accepted for this account") == "provider_quota"
    assert VoiceReasonCode.provider("ElevenLabs session time limit reached") == "session_limit"
    assert VoiceReasonCode.provider(%{code: :not_a_contract_code, message: "ElevenLabs quota exhausted"}) == "provider_quota"
  end

  # A collapsed cause names the collapse: an unknown failure is never a guessed auth or quota error.
  test "an unclassified provider error is provider_error, not a specific cause" do
    assert VoiceReasonCode.provider("socket reset") == "provider_error"
    assert VoiceReasonCode.provider(%{message: "socket reset"}) == "provider_error"
    assert VoiceReasonCode.provider(:weird) == "provider_error"
  end

  test "text-to-speech failures map to their contract codes" do
    assert VoiceReasonCode.tts(:unconfigured) == "unconfigured"
    assert VoiceReasonCode.tts(:not_installed) == "not_installed"
    assert VoiceReasonCode.tts(:capacity) == "capacity"
    assert VoiceReasonCode.tts(:empty_text) == "invalid_payload"
    assert VoiceReasonCode.tts(:text_too_large) == "invalid_payload"
    assert VoiceReasonCode.tts(:unavailable) == "provider_error"
  end

  # Clients ship translations keyed on these strings: renaming or dropping one breaks them.
  test "the closed set is exactly the contract §8 daemon codes" do
    assert Enum.sort(VoiceReasonCode.codes()) ==
             Enum.sort(~w(unconfigured not_installed read_only auth_changed capacity target_not_found
                          target_not_writable target_stale provider_auth provider_quota provider_unavailable
                          chunk_too_large session_limit transport_lost privacy_preflight_failed
                          unsupported_target invalid_payload cost_cap ticket_used provider_error unknown))
  end

  # Event names, payload keys and legacy reason text are the only other
  # snake_case literals in the channel; any new one must be a contract code.
  @not_codes ~w(audio_done audio_error reason_code invalid_topic)

  test "every literal code the voice channel sends is in the closed set" do
    source = File.read!(Path.expand("../../lib/aiur_web/voice_channel.ex", __DIR__))

    for code <- ~w(read_only capacity auth_changed invalid_payload session_limit chunk_too_large not_installed
                   unconfigured provider_unavailable) do
      assert source =~ ~s("#{code}"), "voice_channel.ex no longer sends #{code}"
      assert code in VoiceReasonCode.codes()
    end

    snake_literals = for [_match, literal] <- Regex.scan(~r/"([a-z]+(?:_[a-z]+)+)"/, source), uniq: true, do: literal
    assert Enum.reject(snake_literals, &(&1 in @not_codes or &1 in VoiceReasonCode.codes())) == []
  end

  test "the daemon never sends a client-only code" do
    refute "permission_denied" in VoiceReasonCode.codes()
    refute "no_device" in VoiceReasonCode.codes()
  end
end
