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
    opts = [store: {store, store}, pins: pins, sender: AiurPushRelay.Send]

    children = [
      {store, path: System.get_env("AIUR_RELAY_DATABASE") || "relay.sqlite3", name: store},
      {Task.Supervisor, name: AiurPushRelay.Deliveries},
      {AiurPushRelay.Send,
       name: AiurPushRelay.Send,
       store: {store, store},
       tasks: AiurPushRelay.Deliveries,
       provider: Application.get_env(:aiur_push_relay, :provider, AiurPushRelay.Provider.Disabled)},
      {Bandit, plug: {AiurPushRelay.Router, opts}, port: port()}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end

  defp port, do: String.to_integer(System.get_env("AIUR_RELAY_PORT") || "4001")
end
