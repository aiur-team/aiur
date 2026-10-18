defmodule Aiur.Orchestrator.CommentPolling.Cursor do
  @moduledoc "Comment-poll cursors, discovery cache, and owned-poll bookkeeping."
  @type t :: %__MODULE__{
          since: String.t() | map() | nil,
          etags: map(),
          issue_updated_at: map(),
          issue_list_cache: map(),
          poll: map() | nil,
          reconcile_targets: MapSet.t(String.t()),
          reconcile_timer: map() | nil,
          last_started_at_ms: integer() | nil
        }
  defstruct since: nil, etags: %{}, issue_updated_at: %{}, issue_list_cache: %{}, poll: nil, reconcile_targets: MapSet.new(), reconcile_timer: nil, last_started_at_ms: nil
end
