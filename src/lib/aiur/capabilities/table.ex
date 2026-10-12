defmodule Aiur.Capabilities.Table do
  @moduledoc "Dependency-free ETS owner; monitor restarts preserve the last report and revision."
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    :ets.new(Keyword.get(opts, :table, :aiur_capabilities), [:named_table, :public, read_concurrency: true])
    {:ok, nil}
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}
end
