defmodule Aiur.BuildQueue.ClaimProbe do
  @moduledoc "The build queue's runtime ownership and demand boundary."

  @type claim_status :: :claimed | :unclaimed | {:declined, atom() | {:queue_set_order, String.t()}}
  @type result :: %{String.t() => claim_status()} | :unavailable

  @callback status([String.t()]) :: result()
  @callback notify_demand([String.t()]) :: :ok | :unavailable
  @callback optimistic_records() :: {:ok, [map()]} | {:error, term()}
  @type next_set :: {:ok, String.t() | nil} | :unavailable
  @callback next_set() :: next_set()
  @optional_callbacks optimistic_records: 0, next_set: 0

  @spec next_set(module() | nil) :: next_set()
  def next_set(module \\ impl()) do
    if module && Code.ensure_loaded?(module) && function_exported?(module, :next_set, 0), do: module.next_set(), else: :unavailable
  end

  @spec optimistic_records(module() | nil) :: {:ok, [map()]} | {:error, term()}
  def optimistic_records(module \\ impl()) do
    if module && Code.ensure_loaded?(module) && function_exported?(module, :optimistic_records, 0), do: module.optimistic_records(), else: {:error, :unavailable}
  end

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
