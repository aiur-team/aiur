defmodule Aiur.BuildQueue.Attention do
  @moduledoc """
  Durable queue attentions, serialized by the queue owner.

  The owner must reload Store after these calls before saving its own document.
  Pass nil as the subject of a system attention. Store-unavailable attentions
  need the caller's in-memory latch because this API cannot write a broken store.
  """
  alias Aiur.BuildQueue.Model.Latch
  alias Aiur.BuildQueue.Store
  alias Aiur.Signal

  @ticket_causes [:prerequisite_failed, :dependency_changed_after_start, :promoted_unauthorized, :write_failed, :merged_issue_open, :optimistic_blocker_failed]
  @system_causes [:inputs_unavailable, :store_unavailable]
  @fields [:ticket, :prerequisite, :queue_id, :root, :blocked, :cause, :milestone, :percent, :generation, :freshness, :blocker, :action, :started, :severity]

  @spec open(atom() | tuple(), String.t() | nil, map()) :: :ok | {:error, term()}
  @spec open(atom() | tuple(), String.t() | nil, map(), keyword()) :: :ok | {:error, term()}
  def open(cause, subject, payload, opts \\ [])

  def open(cause, subject, payload, opts) when is_map(payload) do
    store = Keyword.get(opts, :store, Store)
    payload = Map.take(payload, @fields)

    with :ok <- validate_open(kind(cause), subject, payload),
         {:ok, document} <- store.load() do
      key = {cause, subject}
      latch = Enum.find(document.latches, &(&1.key == key)) || %Latch{key: key, opened_at_ms: Keyword.get_lazy(opts, :now_ms, fn -> System.system_time(:millisecond) end)}
      open_latch(document, latch, payload, store)
    end
  end

  def open(_, _, _, _), do: {:error, :invalid_attention}
  defp open_latch(_document, %Latch{emitted?: true}, _payload, _store), do: :ok

  defp open_latch(document, latch, payload, store) do
    {cause, subject} = latch.key

    with :ok <- save_latch(document, latch, store),
         :ok <- emit(kind(cause), subject, payload, false) do
      save_latch(document, %{latch | emitted?: true}, store)
    end
  end

  @spec resolve(atom() | tuple(), String.t() | nil) :: :ok | {:error, term()}
  @spec resolve(atom() | tuple(), String.t() | nil, module()) :: :ok | {:error, term()}
  def resolve(cause, subject, store \\ Store) do
    with :ok <- validate(kind(cause), subject, %{}),
         {:ok, document} <- store.load() do
      case Enum.find(document.latches, &(&1.key == {cause, subject})) do
        nil -> :ok
        latch -> resolve_latch(document, latch, store)
      end
    end
  end

  defp resolve_latch(document, latch, store) do
    {cause, subject} = latch.key

    with :ok <- emit(kind(cause), subject, %{}, true) do
      save_store(store, %{document | latches: Enum.reject(document.latches, &(&1.key == latch.key))})
    end
  end

  defp save_latch(document, latch, store), do: save_store(store, %{document | latches: [latch | Enum.reject(document.latches, &(&1.key == latch.key))]})

  defp save_store(store, document) do
    case store.save(document) do
      :ok -> :ok
      {:error, reason} -> {:error, {:store_unavailable, reason}}
    end
  end

  @spec transient_store(boolean()) :: :ok | {:error, term()}
  def transient_store(resolved?), do: emit(:store_unavailable, nil, %{}, resolved?)

  @spec transient(atom() | tuple(), String.t(), map(), boolean()) :: :ok | {:error, term()}
  def transient(cause, subject, payload, resolved? \\ false) do
    payload = Map.take(payload, @fields)
    validate = if resolved?, do: validate(kind(cause), subject, payload), else: validate_open(kind(cause), subject, payload)
    with :ok <- validate, do: emit(kind(cause), subject, payload, resolved?)
  end

  defp kind({:prerequisite_failed, reason}) when reason in [:agent_error, :pr_closed_unmerged, :not_planned, :duplicate], do: :prerequisite_failed
  defp kind({:optimistic_blocker_failed, reason}) when reason in [:trouble, :churn], do: :optimistic_blocker_failed
  defp kind(cause), do: cause

  # One signal-port seam; only the local feed gets the human-readable copy.
  defp emit(cause, subject, payload, resolved?) do
    prefix = if subject, do: "ticket.#{subject}", else: "system"
    topic = "#{prefix}.queue.attention.#{cause}" <> if(resolved?, do: ".resolved", else: "")
    message = if resolved?, do: "Queue attention #{cause} cleared#{if subject, do: " for ##{subject}", else: ""}.", else: message(cause, subject, payload)

    Signal.alert(topic,
      message: message,
      issue: subject,
      needs_attention: not resolved?,
      severity: if(resolved?, do: "info", else: Map.get(payload, :severity, "warning")),
      durable: true,
      refs_only: true,
      bypass_contamination: true,
      exchange_payload: payload
    )
  end

  defp validate_open(:optimistic_blocker_failed, _subject, payload) when map_size(payload) == 0, do: {:error, :invalid_attention}
  defp validate_open(cause, subject, payload), do: validate(cause, subject, payload)

  defp validate(cause, subject, payload) do
    valid_scope = (cause in @ticket_causes and is_binary(subject) and issue?(subject)) or (cause in @system_causes and is_nil(subject))
    if valid_scope and valid_optimistic?(cause, payload) and Enum.all?(payload, &valid_field?/1), do: :ok, else: {:error, :invalid_attention}
  end

  defp valid_optimistic?(:optimistic_blocker_failed, payload) when map_size(payload) > 0, do: Enum.all?([:blocker, :cause, :action], &Map.has_key?(payload, &1))
  defp valid_optimistic?(_cause, _payload), do: true

  defp issue?(value) when is_binary(value), do: Regex.match?(~r/\A[1-9][0-9]*\z/, value)
  defp issue?(value), do: is_integer(value) and value > 0
  defp valid_field?({key, value}) when key in [:ticket, :prerequisite, :root, :blocker], do: issue?(value)
  defp valid_field?({key, value}) when key in [:blocked, :started] and is_list(value), do: Enum.all?(value, &issue?/1)
  defp valid_field?({:queue_id, value}) when is_binary(value), do: Regex.match?(~r/\Aq-[0-9a-f]{4}\z/, value)
  defp valid_field?({:cause, value}), do: value in (@ticket_causes ++ @system_causes ++ [:agent_error, :pr_closed_unmerged, :not_planned, :duplicate, :edge_removed, :paused, :parked, :todo, :churn])
  defp valid_field?({:milestone, value}), do: value in [25, 50, 75, 100]
  defp valid_field?({:percent, value}), do: is_integer(value) and value in 0..100
  defp valid_field?({:generation, value}), do: is_integer(value) and value >= 0
  defp valid_field?({:freshness, value}), do: value in [:current, :fresh, :stale, :unknown, :unavailable]
  defp valid_field?({:action, value}), do: value in [:paused_parked, :parked, :none]
  defp valid_field?({:severity, value}), do: value in ["info", "warning"]
  defp valid_field?(_), do: false

  defp message(:prerequisite_failed, subject, payload) do
    reason =
      case payload[:cause] do
        :duplicate -> "closed as duplicate (completion unknown)"
        :not_planned -> "closed as not planned"
        :agent_error -> "is in agent:error"
        :pr_closed_unmerged -> "has a PR closed unmerged"
        _ -> "failed"
      end

    blocked = Enum.map_join(Map.get(payload, :blocked, []), ", ", &"##{&1}")

    started =
      case Map.get(payload, :started, []) do
        [] -> ""
        ids -> "; #{Enum.map_join(ids, ", ", &"##{&1}")} already started"
      end

    "##{subject} #{reason}; #{blocked} wait on it#{started}. Re-plan or remove the dependents; ask before reopening the prerequisite."
  end

  defp message(:dependency_changed_after_start, subject, payload) do
    prerequisite = if payload[:prerequisite], do: " (prerequisite ##{payload[:prerequisite]})", else: ""
    "##{subject} became unready after it started#{prerequisite}. Decide whether it pauses; ask the human if unsure."
  end

  defp message(:optimistic_blocker_failed, subject, payload) do
    cause =
      Map.get(
        %{
          pr_closed_unmerged: "has a PR closed unmerged",
          not_planned: "closed as not planned",
          duplicate: "closed as duplicate",
          edge_removed: "was removed from the dependency graph",
          agent_error: "is in agent:error",
          paused: "is paused",
          parked: "is parked",
          todo: "was reset to todo",
          churn: "has repeated conflicting integrations"
        },
        payload[:cause],
        "failed"
      )

    action =
      case payload[:action] do
        :paused_parked -> "Aiur paused and parked ##{subject}; branch and PR kept."
        :parked -> "Aiur parked ##{subject}; branch and PR kept."
        :none -> "##{subject} keeps running."
      end

    "##{subject} started on ##{payload[:blocker]} before it merged; ##{payload[:blocker]} #{cause}. #{action} Choose: wait for a replacement blocker, re-base ##{subject} on the default branch and resume it, or close it."
  end

  defp message(:promoted_unauthorized, subject, _), do: "##{subject} is ready but dispatch is not authorized for it. An allowed human must apply the marker or agent:todo, or hold it."
  defp message(:merged_issue_open, subject, _), do: "The PR for ##{subject} merged; the issue is still open. Close it or explain why it stays open."
  defp message(:inputs_unavailable, _, _), do: "Queue readiness unknown: inputs unavailable. Wait; do not promote by hand."
  defp message(:store_unavailable, _, _), do: "Queue store unavailable; promotion paused. Report it; do not edit labels by hand."
  defp message(:write_failed, subject, _), do: "Cannot write queue labels on ##{subject}. Check GitHub budget and auth; retry with aiur queue recover."
end
