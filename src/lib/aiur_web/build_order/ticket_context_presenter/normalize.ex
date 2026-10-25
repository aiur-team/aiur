defmodule AiurWeb.BuildOrder.TicketContextPresenter.Normalize do
  @moduledoc false

  alias Aiur.Bounded
  alias AiurWeb.BuildOrder.TicketContextPresenter
  alias AiurWeb.BuildOrder.TicketContextPresenter.{Capabilities, Fields, LogEntry, View}

  @max_dependency_tags 25

  @doc false
  @spec normalize_view(View.t() | term()) :: View.t()
  def normalize_view(%View{} = view) do
    identity = Fields.configured_identity(view.identity)

    %View{
      identity: identity,
      repository: Fields.repository_label(identity),
      identifier: Fields.identifier(identity),
      title: Fields.safe_title(view.title, identity),
      description: Fields.safe_description(view.description),
      description_truncated?: view.description_truncated? == true or Fields.description_truncated?(view.description),
      lifecycle: normalized_lifecycle(view.lifecycle),
      detail: normalized_detail(view.detail),
      history: normalized_history(view.history),
      progress: normalized_progress(view.progress),
      latest_evidence: normalized_evidence(view.latest_evidence),
      logs: normalized_logs(view.logs),
      capabilities: Capabilities.normalize_capabilities(view.capabilities, identity),
      dependencies: normalize_dependencies(view.dependencies)
    }
  end

  def normalize_view(_view), do: Fields.unavailable_view()

  # Follow-up (#1270): the OCC ticket-context data path does not yet carry
  # linked-ticket tokens, so callers currently leave dependencies empty and the
  # component renders the tags non-clickable. When the build-order graph is
  # plumbed here, add each tag's linked identity so the modal can mirror the
  # prototype's openTicketModal goto wiring.
  defp normalize_dependencies(dependencies) when is_map(dependencies) do
    %{
      blocked_by: normalize_dependency_tags(Fields.map_value(dependencies, :blocked_by)),
      blocking: normalize_dependency_tags(Fields.map_value(dependencies, :blocking))
    }
  end

  defp normalize_dependencies(_dependencies), do: %{blocked_by: [], blocking: []}

  defp normalize_dependency_tags(tags) when is_list(tags) do
    tags |> Enum.flat_map(&normalize_dependency_tag/1) |> Enum.take(@max_dependency_tags)
  end

  defp normalize_dependency_tags(_tags), do: []

  defp normalize_dependency_tag(tag) when is_map(tag) do
    case Bounded.github_issue_identifier(Fields.map_value(tag, :identifier)) do
      {:ok, identifier} -> [%{identifier: identifier, title: dependency_title(Fields.map_value(tag, :title))}]
      _ -> []
    end
  end

  defp normalize_dependency_tag(_tag), do: []

  defp dependency_title(title) do
    case Fields.safe_text(title, Fields.max_title_bytes()) do
      {:ok, ""} -> nil
      {:ok, safe} -> safe
      :error -> nil
    end
  end

  defp normalized_lifecycle(lifecycle) when is_map(lifecycle) do
    %{
      state: Fields.lifecycle_state(Fields.map_value(lifecycle, :state)),
      reason: Fields.lifecycle_reason(Fields.map_value(lifecycle, :reason))
    }
  end

  defp normalized_lifecycle(_lifecycle), do: %{state: :unknown, reason: :unknown}

  defp normalized_detail(detail) when is_map(detail) do
    %{
      state: Fields.map_value(detail, :state, [:available, :stale, :missing, :unavailable], :unavailable),
      observed_at: Fields.datetime(Fields.map_value(detail, :observed_at)),
      last_success_at: Fields.datetime(Fields.map_value(detail, :last_success_at)),
      last_attempt_at: Fields.datetime(Fields.map_value(detail, :last_attempt_at))
    }
  end

  defp normalized_detail(_detail) do
    %{state: :unavailable, observed_at: nil, last_success_at: nil, last_attempt_at: nil}
  end

  defp normalized_history(history) when is_map(history) do
    %{
      state: Fields.history_state(Fields.map_value(history, :state)),
      freshness: Fields.freshness(Fields.map_value(history, :freshness)),
      observed_at: Fields.datetime(Fields.map_value(history, :observed_at)),
      source_health: Fields.source_health(Fields.map_value(history, :source_health))
    }
  end

  defp normalized_history(_history) do
    %{state: :unavailable, freshness: :unknown, observed_at: nil, source_health: Fields.unavailable_source_health()}
  end

  defp normalized_progress(progress) when is_map(progress) do
    %{
      status: Fields.map_value(progress, :status, [:known, :unknown], :unknown),
      percent: Fields.percent(Fields.map_value(progress, :percent)),
      source: Fields.map_value(progress, :source, [:checkin, :phase], nil),
      occurred_at: Fields.datetime(Fields.map_value(progress, :occurred_at)),
      observed_at: Fields.datetime(Fields.map_value(progress, :observed_at)),
      provenance: Fields.provenance(Fields.map_value(progress, :provenance))
    }
  end

  defp normalized_progress(_progress),
    do: %{status: :unknown, percent: nil, source: nil, occurred_at: nil, observed_at: nil, provenance: %{}}

  defp normalized_evidence(evidence) when is_map(evidence) do
    %{
      status: Fields.map_value(evidence, :status, [:known, :unknown], :unknown),
      source: Fields.evidence_source(Fields.map_value(evidence, :source)),
      occurred_at: Fields.datetime(Fields.map_value(evidence, :occurred_at)),
      observed_at: Fields.datetime(Fields.map_value(evidence, :observed_at)),
      provenance: Fields.provenance(Fields.map_value(evidence, :provenance))
    }
  end

  defp normalized_evidence(_evidence),
    do: %{status: :unknown, source: nil, occurred_at: nil, observed_at: nil, provenance: %{}}

  defp normalized_logs(logs) when is_map(logs) do
    entries = logs |> Fields.map_value(:entries) |> List.wrap() |> Enum.flat_map(&normalized_view_log_entry/1)

    %{
      entries: Enum.take(entries, Fields.max_logs()),
      truncated?: Fields.map_value(logs, :truncated?) == true or length(entries) > Fields.max_logs(),
      observed_at: Fields.datetime(Fields.map_value(logs, :observed_at))
    }
  end

  defp normalized_logs(_logs), do: %{entries: [], truncated?: false, observed_at: nil}

  defp normalized_view_log_entry(%LogEntry{} = entry),
    do:
      TicketContextPresenter.normalized_log_entry(
        entry.event_id,
        entry.kind,
        entry.source,
        entry.label,
        entry.occurred_at,
        entry.observed_at,
        entry.details
      )

  defp normalized_view_log_entry(_entry), do: []
end
