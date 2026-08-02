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
          action_id: String.t() | nil,
          correlation: map() | nil,
          dedupe_key: String.t() | nil,
          causal_refs: [String.t()],
          turn_id: String.t() | nil,
          subscription: map() | nil,
          status: status(),
          delivery_attempts: non_neg_integer(),
          inserted_at: DateTime.t(),
          delivered_at: DateTime.t() | nil,
          provider_delivered_at: DateTime.t() | nil,
          provider_turn_id: String.t() | nil,
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
    :action_id,
    :correlation,
    :dedupe_key,
    :causal_refs,
    :turn_id,
    :subscription,
    :status,
    {:delivery_attempts, 0},
    :inserted_at,
    :delivered_at,
    :provider_delivered_at,
    :provider_turn_id,
    :consumed_at,
    :failed_at,
    :superseded_at,
    :failure_reason
  ]
end
