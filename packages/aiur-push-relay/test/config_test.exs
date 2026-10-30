defmodule AiurPushRelay.ConfigTest do
  use ExUnit.Case, async: false
  alias AiurPushRelay.Config

  test "allowed topic without a pinned fallback refuses to start" do
    old = Application.get_env(:aiur_push_relay, :start_server)
    topics = System.get_env("AIUR_RELAY_APP_TOPICS")
    key = Config.fallback_key("test.boot")
    pin = System.get_env(key)

    on_exit(fn ->
      Application.put_env(:aiur_push_relay, :start_server, old)
      restore("AIUR_RELAY_APP_TOPICS", topics)
      restore(key, pin)
    end)

    Application.put_env(:aiur_push_relay, :start_server, true)
    System.put_env("AIUR_RELAY_APP_TOPICS", "test.boot")
    System.delete_env(key)

    assert AiurPushRelay.Application.start(:normal, []) ==
             {:error, {:missing_fallback, "test.boot"}}
  end

  test "fallbacks use topic slugs and combined UTF-8 byte limits" do
    key = "AIUR_RELAY_FALLBACK_ORG_AIUR_APP"

    env = %{
      "AIUR_RELAY_APP_TOPICS" => "org.aiur-app",
      key => Jason.encode!(%{title: "Aiur", body: "Open"})
    }

    assert Config.load(&Map.get(env, &1)) ==
             {:ok, %{"org.aiur-app" => %{"title" => "Aiur", "body" => "Open"}}}

    invalid = Map.put(env, key, Jason.encode!(%{title: "é", body: String.duplicate("é", 100)}))
    assert Config.load(&Map.get(invalid, &1)) == {:error, {:missing_fallback, "org.aiur-app"}}
  end

  defp restore(key, nil), do: System.delete_env(key)
  defp restore(key, value), do: System.put_env(key, value)
end
