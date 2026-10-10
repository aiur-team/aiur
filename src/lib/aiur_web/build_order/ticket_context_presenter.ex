defmodule AiurWeb.BuildOrder.TicketContextPresenter do
  @moduledoc """
  Pure, bounded presentation data for one configured-repository ticket.

  This module only accepts BO-016 and BO-019 normalized snapshots. It never
  reads provider, process, log, or filesystem state; callers refresh those
  snapshots before asking the component to render.
  """
  alias Aiur.BuildOrder.{Lifecycle, TicketHistory}
  alias Aiur.BuildOrder.TicketDetail.{Snapshot, State}
  alias Aiur.BuildOrder.TicketHistory.Entry
  alias AiurWeb.BuildOrder.TicketContextPresenter.{Capabilities, Capability, Fields, LogEntry, Normalize, View}

  @phase_labels [
    "Brainstorm started",
    "Brainstorm completed",
    "Plan started",
    "Plan completed",
    "Work started",
    "Work completed",
    "Review started",
    "Review completed"
  ]

  @type capability_input :: %{
          required(:kind) => Capability.kind(),
          optional(:variant) => :issue | :pull_request,
          optional(:number) => pos_integer(),
          required(:available?) => boolean(),
          optional(:href) => String.t(),
          optional(:reason) =>
            :identity_mismatch
            | :inactive
            | :invalid_destination
            | :missing
            | :not_available
            | :not_configured
            | :not_opened
            | :stale
            | :unauthorized
            | :unavailable
            | :unreadable
            | :unsupported
        }

  @spec max_description_bytes() :: pos_integer()
  defdelegate max_description_bytes(), to: Fields

  @spec max_logs() :: pos_integer()
  defdelegate max_logs(), to: Fields

  @spec present(State.t(), TicketHistory.Snapshot.t(), [capability_input()]) :: View.t()
  def present(detail, history, capabilities \\ [])

  def present(%State{} = detail, %TicketHistory.Snapshot{} = history, capabilities) when is_list(capabilities) do
    identity = Fields.configured_identity(detail.identity)
    history_matches? = Fields.same_identity?(identity, history.identity)
    detail = detail_view(detail, identity)

    %View{
      identity: identity,
      repository: Fields.repository_label(identity),
      identifier: Fields.identifier(identity),
      title: detail.title,
      description: detail.description,
      description_truncated?: detail.description_truncated?,
      lifecycle: detail.lifecycle,
      detail: Map.take(detail, [:state, :observed_at, :last_success_at, :last_attempt_at]),
      history: history_view(history, history_matches?),
      progress: progress_view(history, history_matches?),
      latest_evidence: latest_evidence_view(history, history_matches?),
      logs: logs_view(history, history_matches?),
      capabilities: normalize_capabilities(capabilities, identity)
    }
    |> normalize_view()
  end

  def present(_detail, _history, _capabilities) do
    Fields.unavailable_view()
  end

  defp detail_view(%State{} = state, identity) do
    snapshot = valid_snapshot(state.detail, identity)

    state_name =
      case {state.health, snapshot} do
        {:healthy, %Snapshot{}} -> :available
        {:stale, %Snapshot{}} -> :stale
        {:healthy, nil} -> :missing
        _ -> :unavailable
      end

    %{
      state: state_name,
      title: snapshot_title(snapshot, identity),
      description: snapshot_description(snapshot),
      description_truncated?: snapshot_description_truncated?(snapshot),
      lifecycle: snapshot_lifecycle(snapshot),
      observed_at: snapshot_observed_at(snapshot),
      last_success_at: Fields.datetime(state.last_success_at),
      last_attempt_at: Fields.datetime(state.last_attempt_at)
    }
  end

  defp valid_snapshot(%Snapshot{identity: snapshot_identity} = snapshot, identity) do
    if Fields.same_identity?(identity, snapshot_identity), do: snapshot
  end

  defp valid_snapshot(_snapshot, _identity), do: nil

  defp snapshot_title(%Snapshot{title: title}, identity), do: Fields.safe_title(title, identity)
  defp snapshot_title(_snapshot, identity), do: Fields.fallback_title(identity)

  defp snapshot_description(%Snapshot{description: description}), do: description
  defp snapshot_description(_snapshot), do: nil

  defp snapshot_description_truncated?(%Snapshot{description: description}), do: Fields.description_truncated?(description)
  defp snapshot_description_truncated?(_snapshot), do: false

  defp snapshot_lifecycle(%Snapshot{lifecycle: %Lifecycle{} = lifecycle}) do
    %{state: Fields.lifecycle_state(lifecycle.state), reason: Fields.lifecycle_reason(lifecycle.state_reason)}
  end

  defp snapshot_lifecycle(_snapshot), do: %{state: :unknown, reason: :unknown}

  defp snapshot_observed_at(%Snapshot{observed_at: observed_at}), do: Fields.datetime(observed_at)
  defp snapshot_observed_at(_snapshot), do: nil

  defp history_view(%TicketHistory.Snapshot{} = history, true) do
    %{
      state: Fields.history_state(history.health),
      freshness: Fields.freshness(history.freshness),
      observed_at: Fields.datetime(history.observed_at),
      source_health: Fields.source_health(history.source_health)
    }
  end

  defp history_view(_history, _matches?) do
    %{state: :unavailable, freshness: :unknown, observed_at: nil, source_health: Fields.unavailable_source_health()}
  end

  defp progress_view(%TicketHistory.Snapshot{progress: progress}, true) when is_map(progress) do
    %{
      status: Fields.map_value(progress, :status, [:known, :unknown], :unknown),
      percent: Fields.percent(Fields.map_value(progress, :percent)),
      source: Fields.map_value(progress, :source, [:checkin, :phase], nil),
      occurred_at: Fields.datetime(Fields.map_value(progress, :occurred_at)),
      observed_at: Fields.datetime(Fields.map_value(progress, :observed_at)),
      provenance: Fields.provenance(Fields.map_value(progress, :provenance))
    }
  end

  defp progress_view(_history, _matches?),
    do: %{status: :unknown, percent: nil, source: nil, occurred_at: nil, observed_at: nil, provenance: %{}}

  defp latest_evidence_view(%TicketHistory.Snapshot{latest_evidence: evidence}, true) when is_map(evidence) do
    %{
      status: Fields.map_value(evidence, :status, [:known, :unknown], :unknown),
      source: Fields.evidence_source(Fields.map_value(evidence, :source)),
      occurred_at: Fields.datetime(Fields.map_value(evidence, :occurred_at)),
      observed_at: Fields.datetime(Fields.map_value(evidence, :observed_at)),
      provenance: Fields.provenance(Fields.map_value(evidence, :provenance))
    }
  end

  defp latest_evidence_view(_history, _matches?),
    do: %{status: :unknown, source: nil, occurred_at: nil, observed_at: nil, provenance: %{}}

  defp logs_view(%TicketHistory.Snapshot{} = history, true) do
    entries = history.entries |> List.wrap() |> Enum.flat_map(&log_entry/1)

    %{
      entries: Enum.take(entries, Fields.max_logs()),
      truncated?: history.truncated? == true or length(entries) > Fields.max_logs(),
      observed_at: Fields.datetime(history.observed_at)
    }
  end

  defp logs_view(_history, _matches?), do: %{entries: [], truncated?: false, observed_at: nil}

  defp log_entry(%Entry{} = entry) do
    normalized_log_entry(
      entry.event_id,
      entry.kind,
      entry.source,
      entry.label,
      entry.occurred_at,
      entry.observed_at,
      entry.details
    )
  end

  defp log_entry(_entry), do: []

  def normalized_log_entry(event_id, kind, source, label, occurred_at, observed_at, details)
      when kind in [
             :agent_attention,
             :agent_decision,
             :agent_lifecycle,
             :branch,
             :continuous_integration,
             :issue,
             :phase,
             :progress,
             :pull_request
           ] and
             source in [:exchange, :issue_log] and is_struct(observed_at, DateTime) do
    [
      %LogEntry{
        event_id: Fields.positive_integer(event_id),
        kind: kind,
        label: log_label(kind, label),
        source: source,
        occurred_at: Fields.datetime(occurred_at),
        observed_at: observed_at,
        details: log_details(kind, details)
      }
    ]
  end

  def normalized_log_entry(_event_id, _kind, _source, _label, _occurred_at, _observed_at, _details), do: []

  defp log_details(:progress, details) when is_map(details) do
    case Fields.map_value(details, :percent) do
      percent when is_integer(percent) and percent in 0..100 -> %{percent: percent}
      _ -> %{}
    end
  end

  defp log_details(:agent_attention, details) when is_map(details) do
    %{}
    |> maybe_put_detail(:severity, Fields.map_value(details, :severity), &(&1 in [:info, :warning, :critical]))
    |> maybe_put_detail(:needs_attention, Fields.map_value(details, :needs_attention), &is_boolean/1)
  end

  defp log_details(_kind, _details), do: %{}

  defp maybe_put_detail(details, key, value, validator) do
    if validator.(value), do: Map.put(details, key, value), else: details
  end

  defp log_label(:agent_attention, _label), do: "Agent attention updated"
  defp log_label(:agent_decision, _label), do: "Agent decision updated"
  defp log_label(:agent_lifecycle, _label), do: "Agent state updated"
  defp log_label(:branch, _label), do: "Branch updated"
  defp log_label(:continuous_integration, _label), do: "Continuous integration updated"
  defp log_label(:issue, _label), do: "Issue updated"
  defp log_label(:progress, _label), do: "Progress updated"
  defp log_label(:pull_request, _label), do: "Pull request updated"
  defp log_label(:phase, label) when label in @phase_labels, do: label
  defp log_label(:phase, _label), do: "Phase updated"

  @doc false
  defdelegate normalize_capabilities(capabilities, identity), to: Capabilities

  @doc false
  defdelegate normalize_view(view), to: Normalize
end
