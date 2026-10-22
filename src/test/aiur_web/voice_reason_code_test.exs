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

  test "the daemon never sends a client-only code" do
    refute "permission_denied" in VoiceReasonCode.codes()
    refute "no_device" in VoiceReasonCode.codes()
  end
end
