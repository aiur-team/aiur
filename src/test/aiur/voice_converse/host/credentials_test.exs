defmodule Aiur.VoiceConverse.Host.CredentialsTest do
  use ExUnit.Case, async: true
  alias Aiur.VoiceConverse.Host.Credentials

  test "probes hide secrets and connections look them up at call time" do
    for {provider, expected_name} <- [openai: "OPENAI_API_KEY", gemini: "GEMINI_API_KEY", anthropic: "ANTHROPIC_API_KEY"] do
      variable = "AIUR_TEST_4115_#{provider}_#{System.unique_integer([:positive])}"
      on_exit(fn -> System.delete_env(variable) end)
      opts = [env_names: %{provider => variable}]
      assert Credentials.fetch(provider, :probe, opts) == {:error, :missing}
      System.put_env(variable, "sentinel-first")
      assert Credentials.fetch(provider, :probe, opts) == {:ok, :present}
      assert Credentials.fetch(provider, :connect, opts) == {:ok, "sentinel-first"}
      assert {:ok, config} = Aiur.VoiceConverse.Host.Config.build(%Aiur.Config.Schema.VoiceConversation{}, "/unused/voice")
      refute inspect(config) =~ "sentinel-first"
      reason = Aiur.VoiceConverse.Host.Capability.resolution_detail(config, {:error, :no_usable_option, [{:cascade, {:missing_credential, provider}}]})
      assert reason.detail == "Cascade skipped: #{expected_name} missing"
      refute inspect(reason) =~ "sentinel-first"
      System.put_env(variable, "sentinel-second")
      assert Credentials.fetch(provider, :connect, opts) == {:ok, "sentinel-second"}
      System.put_env(variable, "  ")
      assert Credentials.fetch(provider, :probe, opts) == {:error, :missing}
    end
  end
end
