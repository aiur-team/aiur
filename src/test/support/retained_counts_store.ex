defmodule Aiur.TestSupport.RetainedCountsStore do
  @moduledoc false

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @spec put_counts(GenServer.server(), map()) :: :ok
  def put_counts(server, counts), do: GenServer.call(server, {:put_counts, counts})

  @impl true
  def init(opts), do: {:ok, Keyword.fetch!(opts, :counts)}

  @impl true
  def handle_call(:retained_counts, _from, counts) do
    {:reply, {:ok, %{counts: counts, health: :writable}}, counts}
  end

  def handle_call({:put_counts, counts}, _from, _current), do: {:reply, :ok, counts}
end
