defmodule LocalHost.PortsTest do
  use ExUnit.Case, async: false

  test "credential probes expose presence and only connection requests return a secret" do
    names = %{
      openai: "OPENAI_API_KEY",
      elevenlabs_agents: "ELEVENLABS_API_KEY",
      gemini: "GEMINI_API_KEY",
      anthropic: "ANTHROPIC_API_KEY"
    }

    previous = Map.new(names, fn {_provider, name} -> {name, System.get_env(name)} end)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    Enum.each(names, fn {provider, name} ->
      System.delete_env(name)
      assert {:error, :missing} = LocalHost.Credentials.fetch(provider, :probe)
      System.put_env(name, "fake-example-secret")
      assert {:ok, :present} = LocalHost.Credentials.fetch(provider, :probe)
      assert {:ok, "fake-example-secret"} = LocalHost.Credentials.fetch(provider, :connect)
    end)
  end

  test "router refuses foreign hosts and a socket without an issued token" do
    port = Application.fetch_env!(:local_host, :port)
    conn = Plug.Test.conn(:get, "http://attacker.invalid:#{port}/")
    assert %{status: 403} = LocalHost.Router.call(conn, [])
    conn = Plug.Test.conn(:get, "http://127.0.0.1:#{port}/voice")

    assert not VoiceConverse.Transport.WebSock.authorized?(conn,
             instance: LocalHost.Voice,
             token_issuer: VoiceConverse.TokenIssuer.Hmac
           )
  end
end
