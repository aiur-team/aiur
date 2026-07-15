defmodule Aiur.BuildOrder.ProviderHealth do
  @moduledoc "Completeness and freshness facts for one provider generation."

  @type state :: :healthy | :stale | :unavailable
  @type t :: %__MODULE__{
          generation: pos_integer() | :unknown,
          state: state(),
          complete?: boolean()
        }

  defstruct generation: :unknown, state: :unavailable, complete?: false

  @spec new(term(), term(), term()) :: t()
  def new(generation, state, complete?) do
    %__MODULE__{
      generation: normalize_generation(generation),
      state: normalize_state(state),
      complete?: complete? == true
    }
  end

  @spec usable?(term()) :: boolean()
  def usable?(%__MODULE__{generation: generation, state: :healthy, complete?: true})
      when is_integer(generation) and generation > 0,
      do: true

  def usable?(_health), do: false

  defp normalize_generation(value) when is_integer(value) and value > 0, do: value
  defp normalize_generation(_value), do: :unknown
  defp normalize_state(state) when state in [:healthy, :stale, :unavailable], do: state
  defp normalize_state(_state), do: :unavailable
end

defmodule Aiur.BuildOrder.Lifecycle do
  @moduledoc "Normalized GitHub issue lifecycle facts without dispatch state."

  @type state :: :open | :closed | :unknown
  @type reason :: :completed | :not_planned | :duplicate | :reopened | :none | :unknown
  @type t :: %__MODULE__{state: state(), state_reason: reason()}

  defstruct state: :unknown, state_reason: :unknown

  @spec from_github(term(), term()) :: t()
  def from_github(state, reason),
    do: %__MODULE__{state: normalize_state(state), state_reason: normalize_reason(reason)}

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{state: :open, state_reason: reason}) when reason in [:none, :reopened],
    do: true

  def valid?(%__MODULE__{state: :closed, state_reason: reason})
      when reason in [:completed, :not_planned, :duplicate],
      do: true

  def valid?(_lifecycle), do: false

  defp normalize_state(value) when value in [:open, "OPEN", "open"], do: :open
  defp normalize_state(value) when value in [:closed, "CLOSED", "closed"], do: :closed
  defp normalize_state(_value), do: :unknown

  defp normalize_reason(nil), do: :none

  defp normalize_reason(value) when value in [:completed, "COMPLETED", "completed"],
    do: :completed

  defp normalize_reason(value) when value in [:not_planned, "NOT_PLANNED", "not_planned"],
    do: :not_planned

  defp normalize_reason(value) when value in [:duplicate, "DUPLICATE", "duplicate"],
    do: :duplicate

  defp normalize_reason(value) when value in [:reopened, "REOPENED", "reopened"], do: :reopened
  defp normalize_reason(_value), do: :unknown
end
