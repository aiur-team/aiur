defmodule Aiur.Cost.StoreSupervisor do
  @moduledoc """
  DynamicSupervisor for per-issue `Aiur.Cost.Store` workers.

  Flat sibling layout mirrors `Aiur.Events.SubscriptionStoreSupervisor` and the
  `Aiur.IssueLog` convention.
  """

  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
