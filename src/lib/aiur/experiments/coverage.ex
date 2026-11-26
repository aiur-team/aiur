defmodule Aiur.Experiments.Coverage do
  @moduledoc "Coverage describes source history independently of sample count."

  @spec classify([term()], Enumerable.t(), map(), DateTime.t() | nil | :unavailable) :: map()
  def classify(_requires, _facts, _window, :unavailable), do: %{state: :unavailable}

  def classify(requires, facts, window, earliest_at) do
    available = Enum.to_list(facts)
    missing = Enum.reject(requires, &(&1 in available))

    cond do
      missing != [] -> %{state: :not_captured, missing: missing}
      is_struct(earliest_at, DateTime) and DateTime.compare(earliest_at, window.start) == :gt -> %{state: :partial, covered_from: earliest_at}
      true -> %{state: :captured}
    end
  end
end
