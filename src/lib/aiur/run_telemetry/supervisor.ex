defmodule Aiur.RunTelemetry.Supervisor do
  @moduledoc false

  use Supervisor

  alias Aiur.RunTelemetry.Writer

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    writer_opts = Keyword.get(opts, :writer_opts, [])
    Supervisor.init([{Writer, writer_opts}], strategy: :one_for_one)
  end
end
