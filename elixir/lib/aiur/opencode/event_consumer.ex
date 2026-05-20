defmodule Aiur.Opencode.EventConsumer do
  @moduledoc false

  use GenServer

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts), do: {:ok, opts}
end
