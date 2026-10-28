defmodule Aiur.Conversation.ResolverSupervisor do
  @moduledoc "Isolates resolver failures from the top-level rest-for-one producer tree."
  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts), do: Supervisor.init([{Aiur.Conversation.AnchorResolver, Keyword.get(opts, :resolver_opts, [])}], strategy: :one_for_one)
end
