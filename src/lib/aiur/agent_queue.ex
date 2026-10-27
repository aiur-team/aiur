defmodule Aiur.AgentQueue do
  @moduledoc """
  Queue-item builders for agent-facing conversation and coordination flows.
  """

  @spec operator_message(String.t(), String.t(), keyword()) :: map()
  def operator_message(issue_identifier, text, opts \\ [])
      when is_binary(issue_identifier) and is_binary(text) do
    %{
      target_issue_identifier: issue_identifier,
      source: :operator,
      category: :operator_message,
      event_type: :text,
      body: %{text: text},
      delivery: operator_delivery(opts),
      action_id: Keyword.get(opts, :action_id),
      correlation: Keyword.get(opts, :correlation),
      causal_refs: Keyword.get(opts, :causal_refs, []),
      turn_id: Keyword.get(opts, :turn_id)
    }
  end

  defp operator_delivery(opts) do
    case Keyword.fetch(opts, :listener_mode) do
      :error -> legacy_delivery(opts)
      {:ok, mode} -> listener_delivery(mode, opts) |> Map.put(:listener_mode_at_claim, mode)
    end
  end

  defp listener_delivery(:sync, opts), do: legacy_delivery(Keyword.put(opts, :delivery_policy, :checkpoint))

  defp listener_delivery(:async, opts) do
    opts
    |> Keyword.put(:delivery_policy, :checkpoint)
    |> legacy_delivery()
    |> Map.merge(%{priority: :later, consume_at: :pull})
  end

  defp listener_delivery(:steer, opts) do
    if Keyword.get(opts, :steer_carrier) != :emulated_interrupt do
      raise ArgumentError, "steer listener mode requires steer_carrier: :emulated_interrupt"
    end

    legacy_delivery(Keyword.put(opts, :delivery_policy, :interrupt))
  end

  defp listener_delivery(mode, _opts), do: raise(ArgumentError, "unsupported listener mode: #{inspect(mode)}")

  defp legacy_delivery(opts) do
    delivery_policy = Keyword.get(opts, :delivery_policy, :checkpoint)
    interrupt_requested = delivery_policy == :interrupt
    immediate = delivery_policy == :immediate

    %{
      priority: if(interrupt_requested or immediate, do: :now, else: :next),
      durability: :durable,
      consume_at: if(immediate, do: :immediate, else: :safe_checkpoint),
      interrupt_requested: interrupt_requested,
      immediate: immediate,
      fallback: Keyword.get(opts, :fallback)
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
        interrupt_requested: Keyword.get(opts, :interrupt_requested, false)
      },
      dedupe_key: Keyword.get(opts, :dedupe_key),
      causal_refs: Keyword.get(opts, :causal_refs, []),
      subscription: Keyword.get(opts, :subscription)
    }
  end
end
