defmodule VoiceConverse.Briefing do
  @moduledoc """
  Generic status card for one target. `render/2` and `diff/2` arrive with MP-E6-C10-T02.

  Fields marked `field/1` in the plan carry `%{value, observed_at, max_age_s}`.
  """

  @type field(t) :: %{value: t, observed_at: DateTime.t(), max_age_s: pos_integer() | nil}

  @type t :: %__MODULE__{
          version: pos_integer(),
          summary: field(String.t()) | nil,
          current_task: field(String.t()) | nil,
          next_steps: field([String.t()]) | nil,
          waiting_on: field(String.t()) | nil,
          questions: field([String.t()]) | nil,
          links: [%{label: String.t(), url: String.t()}],
          extra: [%{title: String.t(), text: String.t(), observed_at: DateTime.t()}],
          gaps: [String.t()]
        }

  defstruct version: 1,
            summary: nil,
            current_task: nil,
            next_steps: nil,
            waiting_on: nil,
            questions: nil,
            links: [],
            extra: [],
            gaps: []
end
