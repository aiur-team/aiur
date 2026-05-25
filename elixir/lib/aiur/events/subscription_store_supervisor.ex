defmodule Aiur.Events.SubscriptionStoreSupervisor do
  @moduledoc """
  DynamicSupervisor for per-issue `Aiur.Events.SubscriptionStore` workers.

  Flat sibling layout (`subscription_store_supervisor.ex` next to
  `subscription_store.ex`) per the repo's existing `Aiur.IssueLog`
  convention — avoids a 3-deep nested module path.
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
