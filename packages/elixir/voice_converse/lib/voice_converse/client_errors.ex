defmodule VoiceConverse.ClientErrors do
  @moduledoc "Stable client-visible end reasons and error codes for voice sessions."

  @table [
    %{code: :user_end, kinds: [:end_reason], retry: :not_applicable, copy_key: "voice.ended.user"},
    %{code: :idle_timeout, kinds: [:end_reason], retry: :now, copy_key: "voice.ended.idle"},
    %{code: :max_duration, kinds: [:end_reason], retry: :now, copy_key: "voice.ended.max_duration"},
    %{code: :target_gone, kinds: [:end_reason], retry: :none, copy_key: "voice.ended.target_gone"},
    %{code: :capability_lost, kinds: [:end_reason], retry: :none, copy_key: "voice.ended.capability_lost"},
    %{code: :auth_changed, kinds: [:end_reason, :error_code], retry: :none, copy_key: "voice.ended.auth_changed"},
    %{code: :cost_cap, kinds: [:end_reason, :error_code], retry: :none, copy_key: "voice.ended.cost_cap"},
    %{code: :provider_quota, kinds: [:end_reason, :error_code], retry: :none, copy_key: "voice.error.provider_quota"},
    %{code: :provider_auth, kinds: [:error_code], retry: :none, copy_key: "voice.error.provider_auth"},
    %{code: :provider_unavailable, kinds: [:error_code], retry: :later, copy_key: "voice.error.provider_unavailable"},
    %{code: :provider_error, kinds: [:end_reason, :error_code], retry: :now, copy_key: "voice.error.provider_error"},
    %{code: :transport_lost, kinds: [:end_reason, :error_code], retry: :now, copy_key: "voice.error.transport_lost"},
    %{code: :daemon_restart, kinds: [:end_reason], retry: :not_applicable, copy_key: "voice.ended.daemon_restart"},
    %{code: :privacy_preflight_failed, kinds: [:error_code], retry: :none, copy_key: "voice.error.privacy_preflight"},
    %{code: :capacity, kinds: [:error_code], retry: :later, copy_key: "voice.error.capacity"},
    %{code: :session_limit, kinds: [:error_code], retry: :later, copy_key: "voice.error.capacity"},
    %{code: :ticket_used, kinds: [:error_code], retry: :now, copy_key: "voice.error.transport_lost"},
    %{code: :unconfigured, kinds: [:error_code], retry: :none, copy_key: "voice.unavailable.unconfigured"},
    %{code: :not_installed, kinds: [:error_code], retry: :none, copy_key: "voice.unavailable.not_installed"},
    %{code: :read_only, kinds: [:error_code], retry: :none, copy_key: "voice.unavailable.read_only"},
    %{code: :target_not_found, kinds: [:error_code], retry: :none, copy_key: "voice.error.target"},
    %{code: :target_not_writable, kinds: [:error_code], retry: :none, copy_key: "voice.error.target"},
    %{code: :target_stale, kinds: [:error_code], retry: :none, copy_key: "voice.error.target"},
    %{code: :unsupported_target, kinds: [:error_code], retry: :none, copy_key: "voice.error.target"},
    %{code: :chunk_too_large, kinds: [:error_code], retry: :now, copy_key: "voice.error.client"},
    %{code: :invalid_payload, kinds: [:error_code], retry: :now, copy_key: "voice.error.client"},
    %{code: :permission_denied, kinds: [:client_error], retry: :none, copy_key: "voice.error.permission_denied"},
    %{code: :no_device, kinds: [:client_error], retry: :none, copy_key: "voice.error.no_device"},
    %{code: :unknown, kinds: [:end_reason, :error_code], retry: :now, copy_key: "voice.error.unknown"}
  ]

  @spec table() :: [map()]
  def table, do: @table

  @spec retry(atom()) :: :none | :now | :later | :not_applicable | nil
  def retry(code), do: lookup(code, :retry)

  @spec copy_key(atom()) :: String.t() | nil
  def copy_key(code), do: lookup(code, :copy_key)

  defp lookup(code, key) do
    case Enum.find(@table, &(&1.code == code)) do
      nil -> nil
      row -> Map.fetch!(row, key)
    end
  end
end
