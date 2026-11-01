defmodule LocalHost.Application do
  @moduledoc false
  use Application
  @impl true
  def start(_type, _args) do
    children = if Application.fetch_env!(:local_host, :start_server), do: children(), else: []
    Supervisor.start_link(children, strategy: :one_for_one, name: LocalHost.Supervisor)
  end

  def children do
    {:ok, config} = LocalHost.voice_config()

    :ok =
      VoiceConverse.TokenIssuer.Hmac.put_secret(LocalHost.Voice, :crypto.strong_rand_bytes(32))

    [
      LocalHost.Files,
      VoiceConverse.child_spec(config),
      {Bandit,
       plug: LocalHost.Router,
       ip: {127, 0, 0, 1},
       port: Application.fetch_env!(:local_host, :port)}
    ]
  end
end
