defmodule AiurWeb.OperatorControlCenter.UnitsRow.Projection do
  @moduledoc false

  alias Aiur.TrackerIdentity
  alias AiurWeb.OperatorControlCenter.UnitsRow.{Fields, Sources, URL, Value}

  @spec rows(map(), map(), Sources.source_set()) :: [map()]
  def rows(membership, indexes, sources) do
    membership
    |> Sources.entries()
    |> Enum.flat_map(&member_rows(&1, indexes, sources))
    |> Enum.sort_by(&Sources.key(&1.identity))
  end

  defp member_rows(member, indexes, sources) do
    with %TrackerIdentity{} = identity <- Sources.identity(member),
         true <- TrackerIdentity.joinable?(identity) do
      [row(member, identity, Sources.matching_rows(identity, indexes), sources)]
    else
      _value -> []
    end
  end

  defp row(member, identity, rows, sources) do
    status_row = rows.status
    activity_row = rows.activity
    decision_row = rows.decisions
    issue_fact = rows.issue
    replacement_boundary? = Fields.replacement_boundary?(status_row)
    terminal? = Map.get(member, :terminal?) == true and not replacement_boundary?
    lifecycle = if replacement_boundary?, do: :waiting, else: Map.get(member, :lifecycle)
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
      reasons: Fields.reasons(status_row, decision_row),
      runtime: Fields.runtime(status_row, member),
      timestamps: timestamps(member, status_row),
      open_command_count: Fields.decision_count(decision_row, status_row),
      progress: Fields.activity_value(activity_row, :progress),
      latest_evidence: Fields.activity_value(activity_row, :latest_evidence),
      provider_health: Sources.health(sources),
      field_sources:
        field_sources(
          values.sources,
          activity_row,
          decision_row,
          status_row
        ),
      sources: source_descriptors(sources, member, rows)
    }
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

  defp field_sources(values, activity_row, decision_row, status_row) do
    %{
      title: values.title,
      url: values.url,
      tracker_state: values.tracker_state,
      lifecycle: :membership,
      backend: values.backend,
      agent_family: values.agent_family,
      requested_model: values.requested_model,
      resolved_model: values.resolved_model,
      effort: values.effort,
      complexity: values.complexity,
      build_lane: values.build_lane,
      progress: if(is_nil(activity_row), do: :unknown, else: :activity),
      open_command_count: Fields.command_count_source(decision_row, status_row)
    }
  end

  defp source_descriptors(sources, member, rows) do
    %{
      membership: Sources.descriptor(sources.membership, member),
      status: Sources.descriptor(sources.status, rows.status),
      activity: Sources.descriptor(sources.activity, rows.activity),
      decisions: Sources.descriptor(sources.decisions, rows.decisions),
      issue: Sources.descriptor(sources.issue, rows.issue)
    }
  end
end
