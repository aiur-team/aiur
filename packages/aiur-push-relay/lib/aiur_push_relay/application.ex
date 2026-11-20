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

    children = [
      {DynamicSupervisor, strategy: :one_for_one, name: AiurPushRelay.Provider.Supervisor},
      {AiurPushRelay.Provider.Router, []},
      {store, path: System.get_env("AIUR_RELAY_DATABASE") || "relay.sqlite3", name: store},
      {Task.Supervisor, name: AiurPushRelay.Deliveries},
      {AiurPushRelay.Send,
       name: AiurPushRelay.Send,
       store: {store, store},
       tasks: AiurPushRelay.Deliveries,
       provider: AiurPushRelay.Provider.Router},
      {Bandit, plug: {AiurPushRelay.Router, configure_providers(pins)}, port: port()}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end

  defp configure_providers(pins) do
    apns_provider =
      Application.get_env(:aiur_push_relay, :provider, AiurPushRelay.Provider.Disabled)

    {fcm_provider, fcm_health} =
      case Application.get_env(:aiur_push_relay, :fcm_provider) do
        nil -> configure_fcm()
        provider -> {provider, "test"}
      end

    provider =
      AiurPushRelay.Provider.Router.new(
        %{"apns" => apns_provider, "fcm" => fcm_provider},
        fcm_health
      )

    :ok = AiurPushRelay.Provider.Router.set_provider(provider)

    [
      store: {AiurPushRelay.Store.SQLite, AiurPushRelay.Store.SQLite},
      pins: pins,
      sender: AiurPushRelay.Send,
      fcm_health: fcm_health
    ]
  end

  defp configure_fcm do
    case AiurPushRelay.Provider.Fcm.configure() do
      {:ok, account, auth_pid} ->
        {{AiurPushRelay.Provider.Fcm, account, auth_pid,
          Application.get_env(:aiur_push_relay, :fcm_request_fun, &Req.post/1)}, "ok"}

      result ->
        result
    end
  end

  defp port, do: String.to_integer(System.get_env("AIUR_RELAY_PORT") || "4001")
end
