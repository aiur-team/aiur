defmodule AiurWeb.OperatorControlCenter.UnitsRow.Projection do
  @moduledoc false

  alias Aiur.CurrentRunMembership.Reconciler
  alias Aiur.LiveConversation.Source, as: LiveConversationSource
  alias Aiur.TrackerIdentity
  alias AiurWeb.OperatorControlCenter.UnitsRow.{Fields, Sources, URL, Value}

  @spec rows(map(), map(), Sources.source_set()) :: [map()]
  def rows(membership, indexes, sources) do
    membership_members = Sources.entries(membership)

    membership_members
    |> add_current_status_members(indexes.status, sources)
    |> Enum.flat_map(fn {origin, member} -> member_rows(origin, member, indexes, sources) end)
    |> Enum.sort_by(&Sources.key(&1.identity))
  end

  defp add_current_status_members(members, status_index, sources) do
    if Sources.current_status?(sources) do
      membership_keys = MapSet.new(members, &(Sources.identity(&1) |> Sources.key()))

      status_members =
        for {key, status_row} <- status_index,
            not MapSet.member?(membership_keys, key),
            do: {:status, status_row}

      Enum.map(members, &{:membership, &1}) ++ status_members
    else
      Enum.map(members, &{:membership, &1})
    end
  end

  defp member_rows(origin, member, indexes, sources) do
    with %TrackerIdentity{} = identity <- Sources.identity(member),
         true <- TrackerIdentity.joinable?(identity) do
      [row(origin, member, identity, Sources.matching_rows(identity, indexes), sources)]
    else
      _value -> []
    end
  end

  defp row(origin, member, identity, rows, sources) do
    status_row = rows.status
    activity_row = rows.activity
    decision_row = rows.decisions
    issue_fact = rows.issue
    replacement_boundary? = Fields.replacement_boundary?(status_row)
    {lifecycle, lifecycle_source} = lifecycle(origin, member, replacement_boundary?)
    terminal? = terminal?(origin, member, lifecycle) and not replacement_boundary?

    {open_command_count, command_count_source} =
      Fields.command_count(decision_row, status_row, Sources.health(sources).decisions)

    values = field_values(issue_fact, status_row)

    %{
      identity: identity,
      title: values.title,
      url: URL.normalize(values.url, identity),
      lifecycle: lifecycle,
      terminal?: terminal?,
      replacement_boundary?: replacement_boundary?,
      tracker_state: values.tracker_state,
      backend: values.backend,
      agent_family: values.agent_family,
      requested_model: values.requested_model,
      resolved_model: values.resolved_model,
      effort: values.effort,
      complexity: values.complexity,
      build_lane: values.build_lane,
      reasons: Fields.reasons(status_row, open_command_count),
      runtime: Fields.runtime(status_row, member),
      timestamps: timestamps(member, status_row),
      open_command_count: open_command_count,
      progress: Fields.activity_value(activity_row, :progress),
      latest_evidence: Fields.activity_value(activity_row, :latest_evidence),
      live_conversation: live_conversation(status_row),
      provider_health: Sources.health(sources),
      field_sources:
        field_sources(
          values.sources,
          activity_row,
          lifecycle_source,
          command_count_source
        ),
      sources: source_descriptors(sources, origin, member, rows)
    }
  end

  defp lifecycle(_origin, _member, true), do: {:waiting, :status_report}

  defp lifecycle(:membership, member, false), do: {Map.get(member, :lifecycle), :membership}

  defp lifecycle(:status, member, false) do
    {Reconciler.lifecycle_for_status_row(Map.get(member, :bucket), member), :status_report}
  end

  defp terminal?(:membership, member, _lifecycle), do: Map.get(member, :terminal?) == true
  defp terminal?(:status, _member, lifecycle), do: lifecycle in [:completed, :cancelled]

  defp live_conversation(%{} = status_row) do
    case Map.get(status_row, :live_conversation) do
      %{generation_handle: handle} = conversation
      when is_binary(handle) ->
        if LiveConversationSource.valid_handle?(handle) do
          public_live_conversation(conversation)
        end

      %{generation_handle: nil, state: state, health: health} = conversation
      when state in [:unavailable, :restart_unknown] and
             health in [:unavailable, :unknown] ->
        public_live_conversation(conversation)

      _conversation ->
        nil
    end
  end

  defp live_conversation(_status_row), do: nil

  defp public_live_conversation(conversation) do
    Map.take(conversation, [
      :generation_handle,
      :state,
      :health,
      :freshness,
      :observed_at,
      :reason
    ])
  end

  defp timestamps(member, status_row) do
    %{
      first_observed_at: Map.get(member, :first_observed_at),
      last_observed_at: Map.get(member, :last_observed_at),
      started_at: Value.get(status_row, :started_at),
      last_activity_at: Value.get(status_row, :last_codex_timestamp) || Value.get(status_row, :last_event_at)
    }
  end

  defp field_values(issue_fact, status_row) do
    {
      {title, title_source},
      {url, url_source},
      {tracker_state, tracker_state_source},
      {backend, backend_source},
      {agent_family, agent_family_source},
      {requested_model, requested_model_source},
      {resolved_model, resolved_model_source},
      {effort, effort_source},
      {complexity, complexity_source},
      {build_lane, build_lane_source}
    } =
      {
        Fields.sourced_value(issue_fact, status_row, [:title]),
        Fields.sourced_value(issue_fact, status_row, [:url]),
        Fields.sourced_value(issue_fact, status_row, [:state]),
        Fields.sourced_value(issue_fact, status_row, [:backend, :selected_backend]),
        Fields.sourced_value(issue_fact, status_row, [:agent_family]),
        Fields.sourced_value(issue_fact, status_row, [:requested_model]),
        Fields.sourced_value(issue_fact, status_row, [:resolved_model]),
        Fields.sourced_value(issue_fact, status_row, [:effort]),
        Fields.sourced_complexity(issue_fact, status_row),
        Fields.sourced_build_lane(issue_fact, status_row)
      }

    %{
      title: title,
      url: url,
      tracker_state: tracker_state,
      backend: backend,
      agent_family: agent_family,
      requested_model: requested_model,
      resolved_model: resolved_model,
      effort: effort,
      complexity: complexity,
      build_lane: build_lane,
      sources: %{
        title: title_source,
        url: url_source,
        tracker_state: tracker_state_source,
        backend: backend_source,
        agent_family: agent_family_source,
        requested_model: requested_model_source,
        resolved_model: resolved_model_source,
        effort: effort_source,
        complexity: complexity_source,
        build_lane: build_lane_source
      }
    }
  end

  defp field_sources(values, activity_row, lifecycle_source, command_count_source) do
    %{
      title: values.title,
      url: values.url,
      tracker_state: values.tracker_state,
      lifecycle: lifecycle_source,
      backend: values.backend,
      agent_family: values.agent_family,
      requested_model: values.requested_model,
      resolved_model: values.resolved_model,
      effort: values.effort,
      complexity: values.complexity,
      build_lane: values.build_lane,
      progress: if(is_nil(activity_row), do: :unknown, else: :activity),
      open_command_count: command_count_source
    }
  end

  defp source_descriptors(sources, origin, member, rows) do
    membership_member = if origin == :membership, do: member

    %{
      membership: Sources.descriptor(sources.membership, membership_member),
      status: Sources.descriptor(sources.status, rows.status),
      activity: Sources.descriptor(sources.activity, rows.activity),
      decisions: Sources.descriptor(sources.decisions, rows.decisions),
      issue: Sources.descriptor(sources.issue, rows.issue)
    }
  end
end
