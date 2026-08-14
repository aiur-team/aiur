defmodule AiurWeb.StreamDeckGrid do
  @moduledoc """
  Purpose-shaped Stream Deck projection over one orchestrator snapshot.

  `agents` is already sorted by the canonical Stream Deck bucket order. The
  controller fills the physical 4-column × 2-row grid column-major:
  `agents[(column_offset + column) * rows_per_column + row]`. Paging is thus
  horizontal by column. `total`, `windows`, and `max_column_offset` let a
  client page without re-deriving fleet state.
  """

  alias Aiur.{AgentEvents, AgentList.Summaries, BuildOrder.Metadata, CodingAgent, Orchestrator}
  alias AiurWeb.StreamdeckKeyFaceContract

  @columns_per_page 4
  @rows_per_column 2
  @agents_per_page @columns_per_page * @rows_per_column

  @spec payload(GenServer.name(), timeout()) :: map()
  def payload(orchestrator, snapshot_timeout_ms) do
    case Orchestrator.dashboard_snapshot(orchestrator, snapshot_timeout_ms) do
      {status, snapshot, freshness} when status in [:current, :stale] ->
        snapshot |> project() |> Map.put(:snapshot_freshness, freshness)

      # The Stream Deck wire contract keeps its published error code; the
      # dashboard reads the richer distinction from `AiurWeb.Presenter`.
      :snapshot_unpublished ->
        %{error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :orchestrator_unavailable ->
        %{error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec project(map()) :: map()
  @spec project(map(), nil | (map() -> boolean())) :: map()
  def project(snapshot, dependency_ready? \\ nil)

  def project(%{} = snapshot, dependency_ready?) do
    fleet = snapshot_agents(snapshot)

    readiness_fun =
      if is_function(dependency_ready?, 1),
        do: dependency_ready?,
        else: &dependency_ready?(&1, fleet)

    agents =
      fleet
      |> Enum.map(fn entry -> {entry, AgentEvents.streamdeck_bucket(entry)} end)
      |> Enum.filter(fn {_entry, bucket} -> StreamdeckKeyFaceContract.known_state?(bucket) end)
      |> Enum.map(fn {entry, bucket} -> {agent_payload(entry, bucket, readiness_fun), priority_rank(entry)} end)
      |> stable_rank()

    total = length(agents)

    %{
      agents: agents,
      total: total,
      columns_per_page: @columns_per_page,
      rows_per_column: @rows_per_column,
      agents_per_page: @agents_per_page,
      windows: ceil_div(total, @agents_per_page),
      max_column_offset: max(ceil_div(total, @rows_per_column) - @columns_per_page, 0)
    }
  end

  defp snapshot_agents(snapshot) do
    for {source, entries} <- [running: Map.get(snapshot, :running, []), retrying: Map.get(snapshot, :retrying, []), queued: Map.get(snapshot, :idle, [])],
        entry <- entries,
        do: Map.put(entry, :streamdeck_source, source)
  end

  defp agent_payload(entry, bucket, dependency_ready?) do
    entry
    |> base_agent_payload(bucket)
    |> maybe_put_dependency_ready(entry, bucket, dependency_ready?)
  end

  defp base_agent_payload(entry, bucket) do
    provider = provider(entry)

    %{
      identifier: Map.get(entry, :identifier),
      title: Map.get(entry, :title),
      icon: build_order_icon(entry),
      vendor: provider.name,
      vendor_logo: provider.logo,
      bucket: bucket,
      progress_percent: progress_percent(entry),
      priority: priority?(entry),
      activity: activity(entry),
      runtime_seconds: runtime_seconds(entry)
    }
  end

  # What the agent is *doing*, as distinct from the lifecycle bucket. Two
  # server-side axes answer that, and they answer different halves of it: the
  # workflow stage (`TicketActivity`) says which part of the turn is running,
  # while `waiting_reason` says the turn is parked on something external. A
  # parked agent's stage is still whatever it was before it parked, so the wait
  # wins — "waiting on CI" is the useful reading, "work" is not.
  #
  # Only the four waits an operator can act on are surfaced. `:active` and the
  # pause/dispatch reasons are already carried by the bucket, and repeating
  # them here would put the same fact on the strip twice.
  @waiting_activities %{
    waiting_for_ci: "waiting_ci",
    waiting_for_review: "waiting_review",
    waiting_for_human: "waiting_human",
    waiting_for_dependency: "waiting_dependency"
  }

  defp activity(entry) do
    case Map.get(@waiting_activities, Map.get(entry, :waiting_reason)) do
      nil -> stage_activity(Map.get(entry, :activity_stage))
      waiting -> waiting
    end
  end

  defp stage_activity(stage) when stage in [:brainstorm, :plan, :work, :review], do: Atom.to_string(stage)
  defp stage_activity(_stage), do: nil

  # Retry rows hard-code `runtime_seconds: 0` and idle rows carry none at all,
  # so a missing value is projected as nil rather than a confident zero: the
  # deck renders "no elapsed time known" differently from "just started".
  defp runtime_seconds(entry) do
    case Map.get(entry, :runtime_seconds) do
      seconds when is_integer(seconds) and seconds > 0 -> seconds
      _ -> nil
    end
  end

  defp maybe_put_dependency_ready(payload, entry, :queued, dependency_ready?),
    do: Map.put(payload, :dependency_ready, dependency_ready?.(entry))

  defp maybe_put_dependency_ready(payload, _entry, _bucket, _dependency_ready?), do: payload

  defp stable_rank(agents) do
    agents
    |> Enum.with_index()
    |> Enum.sort_by(fn {{agent, priority_rank}, index} -> {sort_key(agent, priority_rank), index} end)
    |> Enum.map(fn {{agent, _priority_rank}, _index} -> agent end)
  end

  defp sort_key(%{bucket: bucket, identifier: identifier} = agent, priority_rank) do
    dependency_ready = Map.get(agent, :dependency_ready)
    {StreamdeckKeyFaceContract.bucket_rank!(bucket), if(bucket == :queued and dependency_ready == true, do: 0, else: 1), priority_rank, Summaries.identifier_sort_key(identifier)}
  end

  defp provider(entry) do
    family = Map.get(entry, :agent_family) || CodingAgent.family_for(Map.get(entry, :backend))

    case CodingAgent.provider_descriptor(family) do
      %{provider: provider, logo: logo} -> %{name: Atom.to_string(provider), logo: logo}
      _ -> %{name: family || "unknown", logo: nil}
    end
  end

  defp build_order_icon(entry) do
    entry
    |> Map.get(:labels, [])
    |> Metadata.parse()
    |> Map.fetch!(:lane)
  end

  defp progress_percent(entry) do
    case Map.get(entry, :progress_percent) do
      percent when is_integer(percent) and percent in 0..100 -> percent
      _ -> 0
    end
  end

  defp priority?(entry), do: priority_rank(entry) < 5

  defp priority_rank(entry) do
    case Map.get(entry, :priority) do
      priority when is_integer(priority) and priority > 0 -> priority
      _ -> 5
    end
  end

  @doc """
  Returns whether every explicit upstream dependency is complete in the fleet.

  Readiness has to be earned twice over. The orchestrator's own
  `:waiting_for_dependency` verdict blocks on its own, and beyond that every
  entry in `:blocked_by` must resolve to a fleet member that is merged or at
  100%. An absent `:blocked_by`, an upstream missing from the fleet, or an
  upstream still in flight all read as blocked — the deck never infers
  readiness from a field it did not get.
  """
  @spec dependency_ready?(map(), [map()]) :: boolean()
  def dependency_ready?(agent, fleet) when is_map(agent) and is_list(fleet) do
    with false <- Map.get(agent, :waiting_reason) == :waiting_for_dependency,
         {:ok, blockers} when is_list(blockers) <- Map.fetch(agent, :blocked_by) do
      Enum.all?(blockers, &dependency_satisfied?(&1, fleet))
    else
      _ -> false
    end
  end

  def dependency_ready?(_agent, _fleet), do: false

  defp dependency_satisfied?(blocker, fleet) do
    with blocker_id when not is_nil(blocker_id) <- blocker_identifier(blocker),
         upstream when is_map(upstream) <- Enum.find(fleet, &fleet_entry?(&1, blocker_id)) do
      complete?(upstream)
    else
      _ -> false
    end
  end

  defp blocker_identifier(%{id: id}) when not is_nil(id), do: id
  defp blocker_identifier(%{identifier: identifier}) when not is_nil(identifier), do: identifier
  defp blocker_identifier(identifier) when is_binary(identifier) or is_integer(identifier), do: identifier
  defp blocker_identifier(_blocker), do: nil

  defp fleet_entry?(entry, blocker_id) when is_map(entry) do
    Enum.any?([Map.get(entry, :id), Map.get(entry, :issue_id), Map.get(entry, :identifier)], &same_identifier?(&1, blocker_id))
  end

  defp fleet_entry?(_entry, _blocker_id), do: false

  defp same_identifier?(left, right) when is_binary(left) or is_integer(left), do: to_string(left) == to_string(right)
  defp same_identifier?(_left, _right), do: false

  defp complete?(entry) do
    progress = Map.get(entry, :progress_percent) || Map.get(entry, :pct)

    progress_complete?(progress) or merged_control?(Map.get(entry, :control)) or
      Map.get(entry, :state) in ["Merged", :merged]
  end

  defp progress_complete?(progress) when is_integer(progress), do: progress >= 100
  defp progress_complete?(_progress), do: false

  defp merged_control?(control) when control in ["Merged", :merged], do: true
  defp merged_control?(%{status: status}), do: status in ["Merged", :merged]
  defp merged_control?(_control), do: false

  defp ceil_div(0, _divisor), do: 0
  defp ceil_div(value, divisor), do: div(value + divisor - 1, divisor)
end
