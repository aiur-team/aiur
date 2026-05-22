defmodule Aiur.Opencode.BridgeSupervisor do
  @moduledoc false

  use Supervisor
  require Logger

  alias Aiur.Opencode.Config

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    host = Config.bridge_host()
    port = Application.get_env(:aiur, :opencode_bridge_port_override, Config.bridge_port())

    Logger.warning("opencode_bridge starting host=#{host} port=#{port}")

    children = [
      %{
        id: Bandit,
        start:
          {Bandit, :start_link,
           [
             [
               plug: Aiur.Opencode.Bridge,
               port: port,
               ip: parse_ip(host),
               thousand_island_options: [num_connections: 50]
             ]
           ]},
        restart: :temporary
      }
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp parse_ip(host) do
    host
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, address} -> address
      {:error, _} -> {127, 0, 0, 1}
    end
  end
end
