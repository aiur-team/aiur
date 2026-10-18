defmodule Aiur.GitHub.Listeners.Comments.Input do
  @moduledoc "Orchestrator facts consumed by the comment poll, independent of its State."
  @enforce_keys [:running_targets, :running_titles, :ownership_key, :next_github_delay_ms]
  defstruct @enforce_keys
  @type t :: %__MODULE__{running_targets: [String.t()], running_titles: map(), ownership_key: term(), next_github_delay_ms: non_neg_integer() | nil}
end
