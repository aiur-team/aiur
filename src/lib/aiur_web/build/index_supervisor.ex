defmodule AiurWeb.Build.IndexSupervisor do
  @moduledoc """
  Isolates the build index read model: a crashing index exhausts this
  supervisor's restart limits, never the application's, so it cannot stop the daemon (#4750).
  """
  # Keep index failures isolated from the daemon while ensuring both the index
  # and this supervisor are restarted after transient failures.
  use Supervisor, restart: :permanent
  alias AiurWeb.Build.Index

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts)

  @impl true
  def init(opts), do: Supervisor.init([{Index, opts}], strategy: :one_for_one, max_restarts: 10, max_seconds: 60)
end
