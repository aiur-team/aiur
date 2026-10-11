defmodule Aiur.RunTelemetry.EventFields do
  @moduledoc """
  Metadata the dataset reducer carries from the daemon-side metric events
  (`state_change`, `ci_result`, `pr_ready`, `dependency_cleared`, `ticket_usage`).

  `analytics/lib/analytics/event_fields.py` carries the same list (`EVENT_FIELDS`).
  """

  @fields ~w(from_state to_state blocker head_sha pr_number input_tokens output_tokens cached_tokens cost_amount cost_currency coverage)a

  @spec take(map()) :: %{atom() => term()}
  def take(attributes), do: Map.new(@fields, &{&1, Map.get(attributes, Atom.to_string(&1))})
end
