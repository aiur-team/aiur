defmodule Aiur.BuildOrder.TicketHistory.Normalizer do
  @moduledoc false

  alias Aiur.BuildOrder.TicketHistory.Entry
  alias Aiur.{OpaqueIdentifier, TicketObservation, TrackerIdentity}

  @hard_limit 100
  @progress_names ["progress", "progress.checkin", "progress.phase"]
  @stages [:brainstorm, :plan, :work, :review]
  @transitions [:start, :end]
  @severities ["info", "warning", "critical"]

  @spec hard_limit() :: pos_integer()
  def hard_limit, do: @hard_limit

  @spec from_exchange(term()) :: {:ok, TrackerIdentity.t(), Entry.t()} | :ignore
  def from_exchange(%{ticket_observation: %TicketObservation{} = observation}) do
    with true <- observation.status == :joinable,
         true <- TrackerIdentity.joinable?(observation.tracker_identity),
         {:ok, kind, label, details} <- observation_kind(observation),
         %DateTime{} = observed_at <- observation.observed_at do
      {:ok, observation.tracker_identity,
       %Entry{
         event_id: positive_integer(observation.event_id),
         kind: kind,
         label: label,
         source: :exchange,
         occurred_at: timestamp(observation.occurred_at),
         observed_at: observed_at,
         provenance: provenance(observation.provenance),
         details: details
       }}
    else
      _ -> :ignore
    end
  end

  def from_exchange(_event), do: :ignore

  @spec from_issue_log(term(), TrackerIdentity.t()) :: {:ok, Entry.t()} | :ignore
  def from_issue_log(event, %TrackerIdentity{} = identity) when is_map(event) do
    with true <- issue_log_kind?(field(event, :kind)),
         {:ok, suffix} <- ticket_suffix(field(event, :topic), identity.identifier),
         {:ok, kind, label} <- topic_kind(suffix),
         {:ok, observed_at} <- parse_timestamp(field(event, :ts)),
         event_id when is_integer(event_id) <- positive_integer(field(event, :id)) do
      {:ok,
       %Entry{
         event_id: event_id,
         kind: kind,
         label: label,
         source: :issue_log,
         occurred_at: observed_at,
         observed_at: observed_at,
         provenance: issue_log_provenance(event),
         details: %{}
       }}
    else
      _ -> :ignore
    end
  end

  def from_issue_log(_event, _identity), do: :ignore

  @spec safe_activity(term()) :: map() | nil
  def safe_activity(activity) when is_map(activity) do
    with status when status in [:fresh, :stale] <- activity_status(field(activity, :status)),
         %DateTime{} = observed_at <- timestamp(field(activity, :observed_at)) do
      %{
        status: status,
        active_stage: stage(field(activity, :active_stage)),
        progress: safe_progress(field(activity, :progress)),
        latest_evidence: safe_evidence(field(activity, :latest_evidence)),
        observed_at: observed_at
      }
    else
      _ -> nil
    end
  end

  def safe_activity(_activity), do: nil

  @spec merge_entries([Entry.t()], [Entry.t()], pos_integer()) :: {[Entry.t()], boolean()}
  def merge_entries(existing, incoming, limit) do
    limit = bounded_limit(limit)
    all = Enum.filter(existing ++ incoming, &is_struct(&1, Entry))

    unique =
      all
      |> Enum.reduce(%{}, fn entry, entries ->
        Map.update(entries, dedup_key(entry), entry, &prefer(&1, entry))
      end)
      |> Map.values()
      |> Enum.sort_by(&sort_key/1, :desc)

    {Enum.take(unique, limit), length(unique) > limit}
  end

  @spec bounded_limit(term()) :: pos_integer()
  def bounded_limit(limit) when is_integer(limit) and limit > 0 and limit <= @hard_limit, do: limit
  def bounded_limit(_limit), do: 50

  defp observation_kind(%TicketObservation{
         source: %{kind: :agent_event, name: name},
         attributes: attributes
       })
       when name in @progress_names do
    case field(attributes, :percent) do
      percent when is_integer(percent) and percent in 0..100 ->
        {:ok, :progress, "Progress updated", %{percent: percent}}

      _ ->
        :ignore
    end
  end

  defp observation_kind(%TicketObservation{
         source: %{kind: :agent_alert, name: "phase." <> rest},
         attributes: attributes
       }) do
    with [stage_name, transition_name] <- String.split(rest, ".", parts: 2),
         stage when stage in @stages <- existing_atom(stage_name),
         transition when transition in @transitions <- existing_atom(transition_name),
         ^stage <- field(attributes, :stage),
         ^transition <- field(attributes, :transition) do
      label = if transition == :start, do: "#{stage_label(stage)} started", else: "#{stage_label(stage)} completed"
      {:ok, :phase, label, %{stage: stage, transition: transition}}
    else
      _ -> :ignore
    end
  end

  defp observation_kind(%TicketObservation{source: %{kind: :agent_alert, name: "alert"}, attributes: attributes}) do
    details =
      %{}
      |> maybe_put(:needs_attention, field(attributes, :needs_attention), &is_boolean/1)
      |> maybe_put(:severity, field(attributes, :severity), &(&1 in @severities))

    {:ok, :agent_attention, "Agent attention updated", details}
  end

  defp observation_kind(_observation), do: :ignore

  defp issue_log_kind?(kind), do: kind in ["emit", "emit_alert", "self"]

  defp ticket_suffix(topic, identifier) when is_binary(topic) and is_binary(identifier) do
    prefix = "ticket.#{identifier}."
    if String.starts_with?(topic, prefix), do: {:ok, String.replace_prefix(topic, prefix, "")}, else: :error
  end

  defp ticket_suffix(_topic, _identifier), do: :error

  defp topic_kind("agent.progress" <> rest) when rest in ["", ".checkin", ".phase"],
    do: {:ok, :progress, "Progress updated"}

  defp topic_kind("agent.phase." <> rest) do
    case String.split(rest, ".", parts: 2) do
      [stage, transition]
      when stage in ["brainstorm", "plan", "work", "review"] and transition in ["start", "end"] ->
        label = if transition == "start", do: "#{String.capitalize(stage)} started", else: "#{String.capitalize(stage)} completed"
        {:ok, :phase, label}

      _ ->
        :ignore
    end
  end

  defp topic_kind("agent.attention." <> slug), do: safe_slug(slug, :agent_attention, "Agent attention updated")
  defp topic_kind("agent.decision." <> slug), do: safe_slug(slug, :agent_decision, "Decision state updated")
  defp topic_kind("agent." <> slug), do: safe_slug(slug, :agent_lifecycle, "Agent state updated")
  defp topic_kind("branch.push"), do: {:ok, :branch, "Branch updated"}
  defp topic_kind("pr." <> slug), do: safe_slug(slug, :pull_request, "Pull request updated")
  defp topic_kind("ci." <> slug), do: safe_slug(slug, :continuous_integration, "Continuous integration updated")
  defp topic_kind("issue." <> slug), do: safe_slug(slug, :issue, "Issue updated")
  defp topic_kind(_suffix), do: :ignore

  defp safe_slug(slug, kind, label) do
    if slug != "" and byte_size(slug) <= 128 and Regex.match?(~r/^[a-z0-9_.-]+$/, slug),
      do: {:ok, kind, label},
      else: :ignore
  end

  defp safe_progress(progress) when is_map(progress) do
    %{}
    |> maybe_put(:status, field(progress, :status), &(&1 in [:known, :unknown]))
    |> maybe_put(:freshness, field(progress, :freshness), &(&1 in [:fresh, :stale]))
    |> maybe_put(:percent, field(progress, :percent), &(is_integer(&1) and &1 in 0..100))
    |> maybe_put(:source, field(progress, :source), &(&1 in [:checkin, :phase]))
    |> maybe_put(:event_id, positive_integer(field(progress, :event_id)), &is_integer/1)
    |> maybe_put(:occurred_at, timestamp(field(progress, :occurred_at)), &is_struct(&1, DateTime))
    |> maybe_put(:observed_at, timestamp(field(progress, :observed_at)), &is_struct(&1, DateTime))
    |> maybe_put(:provenance, provenance(field(progress, :provenance)), &(map_size(&1) > 0))
  end

  defp safe_progress(_progress), do: %{status: :unknown}

  defp safe_evidence(evidence) when is_map(evidence) do
    %{}
    |> maybe_put(:status, field(evidence, :status), &(&1 in [:known, :unknown]))
    |> maybe_put(:source, source(field(evidence, :source)), &is_map/1)
    |> maybe_put(:attributes, attributes(field(evidence, :attributes)), &(map_size(&1) > 0))
    |> maybe_put(:provenance, provenance(field(evidence, :provenance)), &(map_size(&1) > 0))
    |> maybe_put(:event_id, positive_integer(field(evidence, :event_id)), &is_integer/1)
    |> maybe_put(:occurred_at, timestamp(field(evidence, :occurred_at)), &is_struct(&1, DateTime))
    |> maybe_put(:observed_at, timestamp(field(evidence, :observed_at)), &is_struct(&1, DateTime))
  end

  defp safe_evidence(_evidence), do: %{status: :unknown}

  defp source(%{kind: kind, name: name})
       when kind in [:agent_event, :agent_alert, :legacy] and is_binary(name) do
    case OpaqueIdentifier.normalize(name) do
      nil -> nil
      safe_name -> %{kind: kind, name: safe_name}
    end
  end

  defp source(_source), do: nil

  defp attributes(attributes) when is_map(attributes) do
    %{}
    |> maybe_put(:percent, field(attributes, :percent), &(is_integer(&1) and &1 in 0..100))
    |> maybe_put(:stage, field(attributes, :stage), &(&1 in @stages))
    |> maybe_put(:transition, field(attributes, :transition), &(&1 in @transitions))
    |> maybe_put(:needs_attention, field(attributes, :needs_attention), &is_boolean/1)
    |> maybe_put(:severity, field(attributes, :severity), &(&1 in @severities))
  end

  defp attributes(_attributes), do: %{}

  defp provenance(provenance) when is_map(provenance) do
    Enum.reduce([:run_id, :attempt, :session_id, :source_event_id], %{}, fn key, result ->
      case field(provenance, key) do
        value when is_integer(value) and value >= 0 -> Map.put(result, key, value)
        value when is_binary(value) -> maybe_put_opaque(result, key, value)
        _ -> result
      end
    end)
  end

  defp provenance(_provenance), do: %{}

  defp issue_log_provenance(event) do
    %{}
    |> maybe_put(:origin, field(event, :source), &(&1 == :github))
    |> maybe_put(:author_trusted?, field(event, :author_trusted?), &is_boolean/1)
  end

  defp activity_status(value) when value in [:fresh, :stale], do: value
  defp activity_status(_value), do: nil
  defp stage(value) when value in @stages, do: value
  defp stage(_value), do: nil

  defp maybe_put(map, _key, nil, _predicate), do: map
  defp maybe_put(map, key, value, predicate), do: if(predicate.(value), do: Map.put(map, key, value), else: map)

  defp maybe_put_opaque(map, key, value) do
    case OpaqueIdentifier.normalize(value) do
      nil -> map
      safe -> Map.put(map, key, safe)
    end
  end

  defp dedup_key(%Entry{event_id: event_id}) when is_integer(event_id), do: {:event_id, event_id}

  defp dedup_key(entry),
    do: {:content, entry.kind, DateTime.to_unix(entry.observed_at, :microsecond), entry.provenance, entry.details}

  defp prefer(%Entry{source: :issue_log}, %Entry{source: :exchange} = incoming), do: incoming
  defp prefer(existing, _incoming), do: existing

  defp sort_key(entry) do
    {DateTime.to_unix(entry.observed_at, :microsecond), entry.event_id || 0, entry.kind}
  end

  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp field(_map, _key), do: nil
  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil
  defp timestamp(%DateTime{} = timestamp), do: timestamp
  defp timestamp(_timestamp), do: nil

  defp parse_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> {:ok, timestamp}
      _ -> :error
    end
  end

  defp parse_timestamp(_value), do: :error

  defp existing_atom(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp stage_label(stage), do: stage |> Atom.to_string() |> String.capitalize()
end
