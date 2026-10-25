defmodule AiurWeb.DeviceVoiceTicket.Used do
  @moduledoc """
  Single-use claims for device voice tickets, retained until ticket expiry.

  The owner keeps only SHA-256 hashes in private ETS. Callers fail closed when
  the owner is unavailable; starting it belongs to the device socket's tree.
  """

  use GenServer

  @sweep_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec claim(<<_::256>>, integer(), GenServer.server()) :: :ok | {:error, :expired | :already_used | :unavailable}
  def claim(hash, expires_at_ms, server \\ __MODULE__) when byte_size(hash) == 32 and is_integer(expires_at_ms) do
    GenServer.call(server, {:claim, hash, expires_at_ms})
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @impl true
  def init(opts) do
    table = :ets.new(__MODULE__, [:set, :private])
    schedule_sweep()
    {:ok, %{table: table, now: Keyword.get(opts, :now, fn -> System.system_time(:millisecond) end)}}
  end

  @impl true
  def handle_call({:claim, hash, expires_at_ms}, _from, state) do
    result =
      cond do
        expires_at_ms <= state.now.() -> {:error, :expired}
        :ets.insert_new(state.table, {hash, expires_at_ms}) -> :ok
        true -> {:error, :already_used}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    :ets.select_delete(state.table, [{{:_, :"$1"}, [{:"=<", :"$1", state.now.()}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_ms)
end
