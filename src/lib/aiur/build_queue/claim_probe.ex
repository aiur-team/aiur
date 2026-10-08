defmodule Aiur.BuildQueue.ClaimProbe do
  @moduledoc "The build queue's runtime ownership and demand boundary."

  @type claim_status :: :claimed | :unclaimed | {:declined, atom()}
  @type result :: %{String.t() => claim_status()} | :unavailable

  @callback status([String.t()]) :: result()
  @callback notify_demand([String.t()]) :: :ok | :unavailable

  @spec impl() :: module() | nil
  def impl, do: Application.get_env(:aiur, :build_queue_claim_probe)

  @spec status([String.t()]) :: result()
  def status(ids) when is_list(ids) do
    case impl() do
      nil -> :unavailable
      module -> module.status(ids)
    end
  end

  @spec notify_demand([String.t()]) :: :ok | :unavailable
  def notify_demand(ids) when is_list(ids) do
    case impl() do
      nil -> :unavailable
      module -> module.notify_demand(ids)
    end
  end
end
