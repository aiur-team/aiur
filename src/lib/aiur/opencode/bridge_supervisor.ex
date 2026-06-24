defmodule Aiur.Opencode.BridgeSupervisor do
  @moduledoc false

  use Supervisor
  require Logger

  alias Aiur.Opencode.BridgePort
  alias Aiur.Opencode.Config

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @doc false
  @spec resolve_bridge_port!(String.t(), {Config.bridge_port_source(), non_neg_integer()}) :: non_neg_integer()
  def resolve_bridge_port!(host, {source, requested_port}) do
    case BridgePort.resolve(host, {source, requested_port}) do
      {:ok, selected_port} ->
        if source == :default and selected_port != requested_port do
          Application.put_env(:aiur, :opencode_bridge_port_override, selected_port)
        end

        selected_port

      {:error, message} ->
        Logger.error(message)
        raise message
    end
  end

  @impl true
  def init(_opts) do
    host = Config.bridge_host()
    port = bridge_port!(host)

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

  defp bridge_port!(host) do
    resolve_bridge_port!(host, Config.bridge_port_with_source())
  end
end
