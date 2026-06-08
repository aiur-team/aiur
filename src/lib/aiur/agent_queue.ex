defmodule Aiur.AgentQueue do
  @moduledoc """
  Queue-item builders for agent-facing conversation and coordination flows.
  """

  @spec operator_message(String.t(), String.t(), keyword()) :: map()
  def operator_message(issue_identifier, text, opts \\ [])
      when is_binary(issue_identifier) and is_binary(text) do
    delivery_policy = Keyword.get(opts, :delivery_policy, :checkpoint)
    interrupt_requested = delivery_policy == :interrupt
    immediate = delivery_policy == :immediate

    %{
      target_issue_identifier: issue_identifier,
      source: :operator,
      category: :operator_message,
      event_type: :text,
      body: %{text: text},
      delivery: %{
        priority: if(interrupt_requested or immediate, do: :now, else: :next),
        durability: :durable,
        consume_at: if(immediate, do: :immediate, else: :safe_checkpoint),
        interrupt_requested: interrupt_requested,
        immediate: immediate,
        fallback: Keyword.get(opts, :fallback)
      },
      causal_refs: Keyword.get(opts, :causal_refs, []),
      turn_id: Keyword.get(opts, :turn_id)
    }
  end

  @spec coordination_event(String.t(), atom(), map(), keyword()) :: map()
  def coordination_event(issue_identifier, event_type, body, opts \\ [])
      when is_binary(issue_identifier) and is_atom(event_type) and is_map(body) do
    %{
      target_issue_identifier: issue_identifier,
      source: Keyword.get(opts, :source, :system),
      category: :coordination_event,
      event_type: event_type,
      body: body,
      delivery: %{
        priority: Keyword.get(opts, :priority, :later),
        durability: :durable,
        consume_at: :safe_checkpoint,
        interrupt_requested: false
      },
      dedupe_key: Keyword.get(opts, :dedupe_key),
      causal_refs: Keyword.get(opts, :causal_refs, []),
      subscription: Keyword.get(opts, :subscription)
    }
  end
end
