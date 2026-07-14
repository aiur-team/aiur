defmodule Aiur.BuildOrder.EdgeState do
  @moduledoc "Conservative native dependency satisfaction states."

  alias Aiur.BuildOrder.{Lifecycle, ProviderHealth}

  @type t :: :cleared | :blocking | :terminal_unsatisfied | :unknown | :cyclic

  @spec classify(term(), term()) :: t()
  def classify(lifecycle, health) do
    if ProviderHealth.usable?(health), do: classify_lifecycle(lifecycle), else: :unknown
  end

  @spec cyclic() :: :cyclic
  def cyclic, do: :cyclic

  defp classify_lifecycle(%Lifecycle{state: :open}), do: :blocking
  defp classify_lifecycle(%Lifecycle{state: :closed, state_reason: :completed}), do: :cleared

  defp classify_lifecycle(%Lifecycle{state: :closed, state_reason: :not_planned}),
    do: :terminal_unsatisfied

  defp classify_lifecycle(_lifecycle), do: :unknown
end

defmodule Aiur.BuildOrder.Readiness do
  @moduledoc "Member readiness derived only from dependency edge states."

  @type t :: :cyclic | :unknown | :terminal_unsatisfied | :blocking | :ready

  @spec from_edges(term()) :: t()
  def from_edges(states) when is_list(states) do
    cond do
      :cyclic in states -> :cyclic
      :unknown in states or Enum.any?(states, &invalid?/1) -> :unknown
      :terminal_unsatisfied in states -> :terminal_unsatisfied
      :blocking in states -> :blocking
      true -> :ready
    end
  end

  def from_edges(_states), do: :unknown

  defp invalid?(state),
    do: state not in [:cleared, :blocking, :terminal_unsatisfied, :unknown, :cyclic]
end
