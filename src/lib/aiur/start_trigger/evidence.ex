defmodule Aiur.StartTrigger.Evidence do
  @moduledoc "Shared prerequisite evidence; `state_label` is an unprefixed lifecycle slug."
  defstruct issue_open?: :unknown, state_reason: nil, state_label: nil, pr: nil, pr_number: nil, stage_reached: nil, observed_at_ms: nil, unavailable_reason: nil

  @type t :: %__MODULE__{
          issue_open?: boolean() | :unknown,
          state_reason: String.t() | nil,
          state_label: String.t() | nil,
          pr: nil | :open | :merged | :closed_unmerged,
          pr_number: pos_integer() | nil,
          stage_reached: Aiur.StartTrigger.trigger() | nil,
          observed_at_ms: integer() | nil,
          unavailable_reason: atom() | nil
        }
end
