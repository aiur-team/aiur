defmodule Aiur.BuildOrder.Index.Rows do
  @moduledoc false
  alias Aiur.BuildOrder.{Epic, FeatureStats, Metadata, ProviderHealth, SourceFreshness}
  alias Aiur.BuildOrder.History.{Edges, Row, Timing}
  alias Aiur.BuildOrder.Index.Catalogue

  @spec build(map(), list()) :: {map(), non_neg_integer()}
  def build(parts, general) do
    history = parts.resolved_history
    {closed, undated} = history |> Map.values() |> Enum.filter(&closed?/1) |> Enum.split_with(&is_integer(SourceFreshness.ms(&1.end)))
    hist = Enum.map(closed, fn row -> %{num: row.number, sec: "hist", status: closure(row.lifecycle.state_reason), ord: SourceFreshness.ms(row.start) || SourceFreshness.ms(row.end)} end)
    claimed = rows(parts[:now]) ++ hist ++ rows(parts[:planned]) ++ rows(parts[:not_queued]) ++ open_rows(parts)
    undated_ids = MapSet.new(undated, & &1.number)
    context = %{general: general, features: feature_epics(parts)}
    edges = edges(parts)
    all = claimed |> Enum.reject(&(MapSet.member?(undated_ids, &1.num) and &1.sec != "now")) |> Enum.uniq_by(& &1.num)

    {Map.new(all, fn row ->
       full = project(row, Map.get(history, row.num, %Row{number: row.num}), parts, context, edges)
       {full.id, full}
     end), length(undated)}
  end

  @spec resolver_context(map(), pos_integer()) :: map()
  def resolver_context(parts, number) do
    row = parts |> Map.get_lazy(:resolved_history, fn -> Map.merge(open_history(parts), history(parts)) end) |> Map.get(number, %Row{})
    registry = Catalogue.registry(parts)
    owner = if registry == :unknown, do: :unknown, else: Map.get(registry.owners, number, :none)

    override =
      case parts[:overrides] do
        {:ok, overrides, _health} -> Map.get(overrides, number, :none)
        _ -> :unknown
      end

    %{labels: row.labels, labels_complete: row.labels_complete, owning_feature: owner, override: override}
  end

  @spec history(map()) :: map()
  def history(%{health: %ProviderHealth{state: state}}) when state in [:unavailable, :structurally_invalid], do: %{}
  def history(%{health: {:error, _}}), do: %{}
  def history(%{history: {:ok, %{rows: rows}}}), do: rows
  def history(_), do: %{}

  @spec open_rows(map()) :: [map()]
  def open_rows(%{open: %{status: status, tickets: tickets}}) when status in [:available, :stale] do
    for ticket <- tickets, is_binary(ticket.identifier), is_binary(ticket.title), {num, ""} <- [Integer.parse(ticket.identifier)], num > 0 do
      cx = Metadata.parse(ticket.labels).complexity
      %{num: num, id: to_string(num), sec: "nq", status: "open", ord: num, title: ticket.title, created: SourceFreshness.ms(ticket.created_at), cx: known(cx), pts: known(FeatureStats.points(cx))}
    end
  end

  def open_rows(_), do: []

  @spec open_history(map()) :: map()
  def open_history(%{open: %{status: status, tickets: tickets}}) when status in [:available, :stale] do
    for ticket <- tickets, is_binary(ticket.identifier), {number, ""} <- [Integer.parse(ticket.identifier)], number > 0, into: %{} do
      {number,
       %Row{number: number, title: ticket.title, labels: ticket.labels, labels_complete: true, created_at: ticket.created_at, lifecycle: %Aiur.BuildOrder.Lifecycle{state: :open, state_reason: :none}}}
    end
  end

  def open_history(_), do: %{}

  defp rows(%{rows: rows}) when is_map(rows), do: Map.values(rows)
  defp rows(%{rows: rows}) when is_list(rows), do: rows
  defp rows(_), do: []
  defp closed?(%{lifecycle: %{state: :closed}}), do: true
  defp closed?(_), do: false
  defp closure(:completed), do: "done"
  defp closure(:not_planned), do: "not_planned"
  defp closure(_), do: "closed"
  defp known(:unknown), do: nil
  defp known(value), do: value

  defp feature_epics(parts) do
    case Catalogue.registry(parts) do
      :unknown -> :unknown
      registry -> Map.new(registry.features, fn {slug, feature} -> {slug, Enum.map(feature.epics, & &1.key)} end)
    end
  end

  defp edges(%{history: {:ok, snapshot}, repository: {:ok, {owner, repository}}}) do
    case Edges.build(snapshot, %{owner: owner, repository: repository}) do
      {:ok, result} -> result.by_ticket
      _ -> %{}
    end
  end

  defp edges(_), do: %{}

  defp project(producer, row, parts, context, edges) do
    cx = Metadata.parse(row.labels).complexity
    resolution = Epic.resolve(resolver_context(parts, producer.num), context)
    {feature, also, added} = membership(parts, producer.num)
    timing = Timing.to_payload(row)

    base = %{
      id: to_string(producer.num),
      num: producer.num,
      title: if(is_binary(row.title), do: row.title, else: ""),
      type: type(row.labels),
      epic: resolution.key,
      feature: feature,
      also: also,
      added: added,
      cx: known(cx),
      pts: known(FeatureStats.points(cx)),
      created: SourceFreshness.ms(row.created_at),
      pct: if(producer.status == "done", do: 100, else: if(producer.sec in ["plan", "nq"], do: 0)),
      agent: agent(row, producer.sec),
      est: nil,
      override: nil,
      wave: nil,
      qpos: nil,
      cue: nil,
      pr: pr(row)
    }

    base |> Map.merge(timing) |> Map.merge(Edges.to_payload(edges, producer.num)) |> Map.merge(producer) |> Map.update!(:created, &SourceFreshness.ms/1) |> align_dependencies()
  end

  defp align_dependencies(row) do
    %{row | dep_states: Map.new(row.deps, &{&1, Map.get(row.dep_states, &1, "unknown")})}
  end

  defp membership(parts, number) do
    case Catalogue.registry(parts) do
      :unknown ->
        {nil, [], false}

      registry ->
        owner = registry.owners[number]
        feature = if owner, do: owner.feature
        baseline = if feature, do: registry.features[feature].baseline, else: :none
        {feature, Map.get(registry.also, number, []), baseline != :none and not MapSet.member?(baseline.members, number)}
    end
  end

  defp type(labels) when is_list(labels) do
    cond do
      "bug" in labels -> "bug"
      "docs" in labels or "documentation" in labels -> "docs"
      "chore" in labels or "refactor" in labels -> "chore"
      true -> "feature"
    end
  end

  defp type(_), do: "feature"
  defp agent(%{agent_model: model, agent_effort: effort}, "hist") when is_binary(model), do: %{model: model, name: nil, effort: if(is_binary(effort), do: effort), state: nil}
  defp agent(_, _), do: nil
  defp pr(%{pr_number: number, merged_at: %DateTime{}}) when is_integer(number), do: %{num: number, state: "merged"}
  defp pr(_), do: nil
end
