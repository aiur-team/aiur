defmodule AiurWeb.VoiceReasonCode do
  @moduledoc """
  Stable, client-translatable `reason_code` values for the voice channel
  (voice-session contract §8).

  Every join refusal and every `error`/`audio_error` push carries one of
  `codes/0` next to its unchanged `reason` text, so a phone, watch or
  dashboard can translate and decide on retry without parsing English. A
  failure of no known class stays cause-neutral (`provider_error` from a
  provider, `unknown` from the daemon); it is never relabelled as a specific
  cause such as auth or quota.
  """

  # Daemon-side codes from contract §8. The client-only codes
  # (`permission_denied`, `no_device`) are never sent by the daemon.
  @codes ~w(unconfigured not_installed read_only auth_changed capacity target_not_found
            target_not_writable target_stale provider_auth provider_quota provider_unavailable
            chunk_too_large session_limit transport_lost privacy_preflight_failed
            unsupported_target invalid_payload cost_cap ticket_used provider_error unknown)

  @code_atoms Map.new(@codes, &{String.to_atom(&1), &1})

  # Fallback for a sender that still passes bare provider text instead of
  # `%{code, message}`. Only causes the provider names outright are mapped.
  @provider_texts %{
    "ElevenLabs rejected the API key" => "provider_auth",
    "ElevenLabs quota exhausted" => "provider_quota",
    "ElevenLabs rate limit reached" => "provider_quota",
    "ElevenLabs terms not accepted for this account" => "provider_quota",
    "ElevenLabs session time limit reached" => "session_limit"
  }

  @doc "The closed set of codes the daemon sends."
  @spec codes() :: [String.t()]
  def codes, do: @codes

  @doc """
  The code for a provider `{:voice_error, …}`: the carried code when it is in
  the closed set, else the bare-text fallback, else `provider_error`.
  """
  @spec provider(%{optional(:code) => term(), optional(:message) => term()} | String.t()) :: String.t()
  def provider(%{code: code}) when is_map_key(@code_atoms, code), do: Map.fetch!(@code_atoms, code)
  def provider(%{message: message}) when is_binary(message), do: provider(message)
  def provider(message) when is_binary(message), do: Map.get(@provider_texts, message, "provider_error")
  def provider(_error), do: "provider_error"

  @doc "The code for a text-to-speech start failure reason."
  @spec tts(term()) :: String.t()
  def tts(:unconfigured), do: "unconfigured"
  def tts(:not_installed), do: "not_installed"
  def tts(:capacity), do: "capacity"
  def tts(reason) when reason in [:empty_text, :text_too_large], do: "invalid_payload"
  def tts(_reason), do: "provider_error"
end
