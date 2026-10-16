defmodule AiurWeb.Build.IndexSupervisor do
  @moduledoc """
  Isolates the build index read model: a crashing index exhausts this
  supervisor's restart limits, never the application's, so it cannot stop the daemon (#4750).
  """
  # ponytail: temporary, so a persistently crashing index stays down (the board reads
  # :index_not_running) until the next daemon restart; add a backoff restart if that bites.
  use Supervisor, restart: :temporary
  alias AiurWeb.Build.Index

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts)

  @impl true
  def init(opts), do: Supervisor.init([{Index, opts}], strategy: :one_for_one, max_restarts: 3, max_seconds: 5)
end
