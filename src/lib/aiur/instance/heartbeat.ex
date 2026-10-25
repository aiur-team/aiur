defmodule Aiur.Instance.Heartbeat do
  @moduledoc "Publishes instance liveness independently of ticket leases."
  use GenServer

  require Logger

  alias Aiur.Instance.LeaseStore

  @interval_ms 10_000
  @ttl_ms 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @interval_ms),
      ttl_ms: Keyword.get(opts, :ttl_ms, @ttl_ms),
      metadata_fun:
        Keyword.get(opts, :metadata_fun, fn ->
          case Application.get_env(:aiur, :instance_heartbeat_metadata) do
            metadata when is_map(metadata) -> metadata
            metadata_fun when is_function(metadata_fun, 0) -> metadata_fun.()
            _ -> Aiur.Instance.heartbeat_metadata()
          end
        end),
      version: Keyword.get(opts, :build_version, Application.spec(:aiur, :vsn) |> to_string())
    }

    send(self(), :publish)
    {:ok, state}
  end

  @impl true
  def handle_info(:publish, state) do
    case LeaseStore.heartbeat(state.version, state.metadata_fun.(), ttl_ms: state.ttl_ms) do
      {:ok, _instances} -> :ok
      {:error, reason} -> Logger.warning("instance heartbeat unavailable: #{inspect(reason)}")
    end

    Process.send_after(self(), :publish, state.interval_ms)
    {:noreply, state}
  end
end
