defmodule Aiur.AgentQueueItem do
  @moduledoc """
  Normalized queue item envelope for agent-facing messages and events.
  """

  @type status :: :pending | :delivered | :consumed | :failed | :superseded
  @type priority :: :now | :next | :later
  @type category :: :operator_message | :coordination_event | :system_notice

  @type t :: %__MODULE__{
          id: integer(),
          sequence: integer(),
          target_issue_identifier: String.t(),
          source: atom(),
          category: category(),
          event_type: atom(),
          body: map(),
          delivery: map(),
          dedupe_key: String.t() | nil,
          causal_refs: [String.t()],
          subscription: map() | nil,
          status: status(),
          inserted_at: DateTime.t(),
          delivered_at: DateTime.t() | nil,
          consumed_at: DateTime.t() | nil,
          failed_at: DateTime.t() | nil,
          superseded_at: DateTime.t() | nil,
          failure_reason: term() | nil
        }

  defstruct [
    :id,
    :sequence,
    :target_issue_identifier,
    :source,
    :category,
    :event_type,
    :body,
    :delivery,
    :dedupe_key,
    :causal_refs,
    :subscription,
    :status,
    :inserted_at,
    :delivered_at,
    :consumed_at,
    :failed_at,
    :superseded_at,
    :failure_reason
  ]
end
