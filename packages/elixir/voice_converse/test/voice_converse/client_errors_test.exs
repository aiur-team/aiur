defmodule VoiceConverse.ClientErrorsTest do
  use ExUnit.Case, async: true

  alias VoiceConverse.ClientErrors

  test "has a stable row for every session end reason and emitted provider error" do
    rows = Map.new(ClientErrors.table(), &{&1.code, &1})

    for code <- [
          :user_end,
          :idle_timeout,
          :max_duration,
          :target_gone,
          :capability_lost,
          :auth_changed,
          :cost_cap,
          :provider_quota,
          :provider_error,
          :transport_lost,
          :daemon_restart,
          :unknown
        ] do
      assert %{kinds: kinds, retry: retry, copy_key: copy_key} = Map.fetch!(rows, code)
      assert :end_reason in kinds
      assert retry in [:none, :now, :later, :once, :not_applicable]
      assert is_binary(copy_key)
    end

    for code <- [:provider_auth, :provider_quota, :provider_unavailable, :privacy_preflight_failed, :provider_error] do
      assert :error_code in Map.fetch!(rows, code).kinds
    end
  end
end
