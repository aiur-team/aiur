defmodule Aiur.Orchestrator.Reconciler.Divergence do
  @moduledoc false

  alias Aiur.{Alerts, Issue}
  alias Aiur.Orchestrator.State

  # A label-override pause is authoritative only while the tracker still carries
  # `agent:paused`. If it disappears while the in-memory entry remains paused,
  # the Executor otherwise sees two incompatible fleet states until this poll
  # happens to resume the worker. Emit before reconciliation repairs it so the
  # discrepancy is visible in the alert feed.
  @doc false
  @spec report_label_divergence(State.t(), Issue.t()) :: State.t()
  def report_label_divergence(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{} = entry ->
        identifier = Map.get(entry, :identifier) || issue.identifier || issue.id

        case label_divergence(entry, issue) do
          nil ->
            clear_reported_divergence(state, issue.id)

          reason ->
            report_label_divergence_once(state, issue, entry, identifier, reason)
        end

      _ ->
        clear_reported_divergence(state, issue.id, issue.identifier)
    end
  end

  @doc false
  @spec resolve_orphaned_divergence_attentions(State.t()) :: State.t()
  def resolve_orphaned_divergence_attentions(%State{} = state) do
    running_identifiers =
      state.running
      |> Map.values()
      |> Enum.flat_map(fn entry ->
        case Map.get(entry, :identifier) || get_in(entry, [:issue, Access.key(:identifier)]) do
          identifier when is_binary(identifier) and identifier != "" -> [identifier]
          _ -> []
        end
      end)
      |> MapSet.new()

    state.active_attention_topics
    |> Enum.reduce(state, &resolve_orphaned_divergence_attention(&2, &1, running_identifiers))
  end

  defp resolve_orphaned_divergence_attention(state, topic, running_identifiers) do
    identifier = divergence_identifier(topic)

    cond do
      not is_binary(identifier) -> state
      MapSet.member?(running_identifiers, identifier) -> state
      true -> emit_divergence_resolution(state, identifier, nil, identifier, topic)
    end
  end

  defp divergence_identifier("ticket." <> rest) do
    suffix = ".agent.attention.state_divergence"

    if String.ends_with?(rest, suffix), do: String.trim_trailing(rest, suffix)
  end

  defp divergence_identifier(_topic), do: nil

  defp label_divergence(%{control: %{status: :paused}, paused_reason: :label_override}, %Issue{} = issue)
       when not is_nil(issue) do
    unless Issue.paused?(issue),
      do: "State reconciliation detected divergence: local=paused(label_override) tracker=agent:#{issue.state}."
  end

  defp label_divergence(%{control: %{status: :paused}, paused_reason: :max_agent_duration}, %Issue{} = issue)
       when not is_nil(issue) do
    unless Issue.paused?(issue),
      do: "State reconciliation detected divergence: local=paused(max_agent_duration) tracker=agent:#{issue.state}; the automatic release did not complete, so operator resume is required."
  end

  defp label_divergence(%{control: %{status: status}}, %Issue{} = issue) when status in [:working, :sleeping] do
    if Issue.paused?(issue),
      do: "State reconciliation detected divergence: local=#{status} tracker=agent:paused."
  end

  defp label_divergence(_entry, _issue), do: nil

  defp report_label_divergence_once(state, issue, entry, identifier, reason) do
    topic = "ticket.#{identifier}.agent.attention.state_divergence"
    entry = Map.delete(entry, :label_divergence_attention_checked)

    if Map.get(entry, :label_divergence_reported) == reason or active_attention?(state, topic) do
      put_in(state.running[issue.id], Map.put(entry, :label_divergence_reported, reason))
    else
      Alerts.emit_custom(topic, reason,
        issue: identifier,
        workspace: Map.get(entry, :workspace_path),
        worker_host: Map.get(entry, :worker_host),
        reason: reason,
        needs_attention: true,
        severity: "warning",
        central: true
      )

      put_in(state.running[issue.id], Map.put(entry, :label_divergence_reported, reason))
    end
  end

  @doc false
  @spec clear_reported_divergence(State.t(), String.t(), String.t() | nil) :: State.t()
  def clear_reported_divergence(state, issue_id, fallback_identifier \\ nil) do
    case Map.get(state.running, issue_id) do
      %{} = entry ->
        clear_entry_divergence(state, issue_id, entry)

      _ when is_binary(fallback_identifier) and fallback_identifier != "" ->
        clear_persisted_divergence(state, issue_id, fallback_identifier)

      _ ->
        state
    end
  end

  defp clear_persisted_divergence(state, issue_id, identifier) do
    topic = "ticket.#{identifier}.agent.attention.state_divergence"

    if active_attention?(state, topic) do
      emit_divergence_resolution(state, issue_id, nil, identifier, topic)
    else
      state
    end
  end

  defp clear_entry_divergence(state, issue_id, entry) do
    identifier = Map.get(entry, :identifier) || issue_id
    topic = "ticket.#{identifier}.agent.attention.state_divergence"

    if reported_divergence_active?(state, entry, topic) do
      emit_divergence_resolution(state, issue_id, entry, identifier, topic)
    else
      mark_divergence_checked(state, issue_id, entry)
    end
  end

  defp reported_divergence_active?(state, entry, topic) do
    Map.has_key?(entry, :label_divergence_reported) or
      (not Map.get(entry, :label_divergence_attention_checked, false) and
         active_attention?(state, topic))
  end

  defp active_attention?(state, topic), do: MapSet.member?(state.active_attention_topics, topic)

  defp emit_divergence_resolution(state, issue_id, entry, identifier, topic) do
    metadata = entry || %{}
    previous_reason = Map.get(metadata, :label_divergence_reported, "the prior divergence")

    case Alerts.emit_custom(
           "#{topic}.resolved",
           "Tracker/local state reconciliation recovered for ticket #{identifier}.",
           issue: identifier,
           workspace: Map.get(metadata, :workspace_path),
           worker_host: Map.get(metadata, :worker_host),
           reason: "Resolved: #{previous_reason}",
           needs_attention: false,
           severity: "info",
           central: true
         ) do
      :ok -> mark_divergence_checked(state, issue_id, entry)
      {:error, _reason} -> state
    end
  end

  defp mark_divergence_checked(state, issue_id, entry) when is_map(entry) do
    checked_entry =
      entry
      |> Map.delete(:label_divergence_reported)
      |> Map.put(:label_divergence_attention_checked, true)

    put_in(state.running[issue_id], checked_entry)
  end

  defp mark_divergence_checked(state, _issue_id, nil), do: state
end
