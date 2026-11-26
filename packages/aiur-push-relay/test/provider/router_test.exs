defmodule AiurPushRelay.Provider.RouterTest do
  use ExUnit.Case, async: false

  alias AiurPushRelay.Provider.{Fake, Router}

  test "router loads the configured test FCM provider on startup" do
    previous = Application.get_env(:aiur_push_relay, :fcm_provider)
    Application.put_env(:aiur_push_relay, :fcm_provider, Fake)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:aiur_push_relay, :fcm_provider),
        else: Application.put_env(:aiur_push_relay, :fcm_provider, previous)
    end)

    start_supervised!({Router, []})

    assert Router.provider() == Fake
    assert Router.health().fcm == "test"
  end
end
