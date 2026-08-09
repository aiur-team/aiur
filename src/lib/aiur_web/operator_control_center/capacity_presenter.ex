defmodule AiurWeb.OperatorControlCenter.CapacityPresenter do
  @moduledoc """
  Stable accessible labels over the authoritative runtime max-agent capacity
  facts returned by `Aiur.Orchestrator.Slots.max_concurrent_agent_status/1`.

  The presenter never derives capacity from rendered rows. When an authoritative
  fact is absent it is labelled unknown rather than inferred. The UI minimum is
  `1`; zero never means a global pause.
  """

  @min 1

  @type fact :: pos_integer() | non_neg_integer() | nil

  @type t :: %{
          available?: boolean(),
          active: fact(),
          max: fact(),
          configured: fact(),
          session_override?: boolean(),
          draining?: boolean(),
          min: pos_integer(),
          can_decrement?: boolean(),
          active_label: String.t(),
          max_label: String.t(),
          source_label: String.t(),
          state_label: String.t(),
          summary: String.t()
        }

  @spec present(map() | nil | :unavailable) :: t()
  def present(%{} = capacity) do
    active = non_negative(Map.get(capacity, :active))
    max = positive(Map.get(capacity, :max))
    configured = positive(Map.get(capacity, :configured))
    session_override? = Map.get(capacity, :session_override?) == true
    draining? = Map.get(capacity, :draining?) == true

    %{
      available?: true,
      active: active,
      max: max,
      configured: configured,
      session_override?: session_override?,
      draining?: draining?,
      min: @min,
      can_decrement?: is_integer(max) and max > @min,
      active_label: number_label(active),
      max_label: number_label(max),
      source_label: source_label(session_override?, configured),
      state_label: state_label(draining?, max),
      summary: summary(active, max, draining?, session_override?)
    }
  end

  def present(_capacity) do
    %{
      available?: false,
      active: nil,
      max: nil,
      configured: nil,
      session_override?: false,
      draining?: false,
      min: @min,
      can_decrement?: false,
      active_label: "Unknown",
      max_label: "Unknown",
      source_label: "Capacity source unknown",
      state_label: "Capacity unavailable",
      summary: "Runtime capacity is unavailable."
    }
  end

  @spec min() :: pos_integer()
  def min, do: @min

  defp source_label(true, configured) when is_integer(configured),
    do: "Session override (configured #{configured})"

  defp source_label(true, _configured), do: "Session override"
  defp source_label(false, configured) when is_integer(configured), do: "Configured default"
  defp source_label(false, _configured), do: "Capacity source unknown"

  defp state_label(true, max) when is_integer(max),
    do: "Draining above #{max} maximum"

  defp state_label(true, _max), do: "Draining"
  defp state_label(false, _max), do: "Steady"

  defp summary(active, max, draining?, session_override?) do
    active_part = if is_integer(active), do: "#{active} active", else: "active count unknown"
    max_part = if is_integer(max), do: "maximum #{max}", else: "maximum unknown"
    source_part = if session_override?, do: ", session override", else: ""
    state_part = if draining?, do: ", draining", else: ""

    "Runtime capacity: #{active_part}, #{max_part}#{source_part}#{state_part}."
  end

  defp number_label(value) when is_integer(value), do: Integer.to_string(value)
  defp number_label(_value), do: "Unknown"

  defp positive(value) when is_integer(value) and value > 0, do: value
  defp positive(_value), do: nil

  defp non_negative(value) when is_integer(value) and value >= 0, do: value
  defp non_negative(_value), do: nil
end
