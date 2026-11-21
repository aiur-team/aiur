defmodule AiurPushRelay.Application do
  @moduledoc false
  use Application

  def start(_type, _args) do
    if Application.get_env(:aiur_push_relay, :start_server, true) do
      with {:ok, pins} <- AiurPushRelay.Config.load() do
        start_relay(pins)
      end
    else
      Supervisor.start_link([], strategy: :one_for_one, name: __MODULE__)
    end
  end

  defp start_relay(pins) do
    AiurPushRelay.LogFilter.install()
    store = AiurPushRelay.Store.SQLite

    children =
      [
        {DynamicSupervisor, strategy: :one_for_one, name: AiurPushRelay.Provider.Supervisor}
      ] ++
        apns_children(pins) ++
        [
          {AiurPushRelay.Provider.Router, []},
          {store, path: System.get_env("AIUR_RELAY_DATABASE") || "relay.sqlite3", name: store},
          {Task.Supervisor, name: AiurPushRelay.Deliveries},
          {AiurPushRelay.Send,
           name: AiurPushRelay.Send,
           store: {store, store},
           tasks: AiurPushRelay.Deliveries,
           provider: AiurPushRelay.Provider.Router},
          {Bandit,
           plug:
             {AiurPushRelay.Router,
              [
                store: {store, store},
                pins: pins,
                sender: AiurPushRelay.Send,
                providers: AiurPushRelay.Provider.Router
              ]},
           port: port()}
        ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end

  defp apns_children(pins) do
    case AiurPushRelay.Provider.Apns.Jwt.load() do
      {:ok, config} ->
        Application.put_env(:aiur_push_relay, :apns, pins: pins, jwt: AiurPushRelay.ApnsJwt)

        [
          {AiurPushRelay.Provider.Apns.Jwt, config: config, name: AiurPushRelay.ApnsJwt},
          {Finch, name: AiurPushRelay.ApnsFinch, pools: %{default: [protocols: [:http2]]}}
        ]

      {:error, :unavailable} ->
        []
    end
  end

  defp port, do: String.to_integer(System.get_env("AIUR_RELAY_PORT") || "4001")
end
