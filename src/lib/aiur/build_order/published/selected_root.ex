defmodule Aiur.BuildOrder.Published.SelectedRoot do
  @moduledoc """
  The selected-root `build-order.v1` document.

  One epic for the root, its pack workstreams as features, every present lane,
  and every typed edge the projection can prove. Waves, dependency states and
  the critical path reuse `Aiur.BuildOrder.GraphAnalysis` and
  `Aiur.BuildOrder.EdgeState`, so the published document cannot disagree with
  the dashboard about what blocks what.
  """

  alias Aiur.BuildOrder.{
    Dependency,
    EdgeState,
    Estimates,
    FeatureStats,
    Member,
    Metadata,
    SelectedRoot
  }

  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.BuildOrder.Published.{Document, Graph, Pack, Progress, Sources}
  alias Aiur.TrackerIdentity

  @ticket_kinds ~w(executable audit gate umbrella capstone unknown)
  @provenances ~w(planned discovered unknown)

  @spec document(Snapshot.t(), SelectedRoot.t(), DateTime.t(), keyword()) :: map()
  def document(snapshot, %SelectedRoot{} = selected, now, opts) do
    metadata = Pack.pack_metadata(selected)
    health = snapshot.health
    tracker = Sources.tracker(health)
    available? = Sources.available?(health)
    reason = Sources.reason(health)

    relations = Pack.relation_records(metadata, opts)
    gates = Pack.gate_records(metadata, opts)
    gate_keys = MapSet.new(gates, & &1["key"])

    rows =
      selected.members
      |> Enum.filter(&match?(%Member{}, &1))
      |> Enum.map(&row(&1, relations))
      |> Enum.sort_by(&Document.sort_key(&1.id))

    feature_records = Pack.feature_records(metadata, rows)
    epic_key = Pack.epic_key(metadata, selected)
    epic = Pack.epic_record(selected, epic_key, feature_records)

    facts =
      Enum.map(rows, fn row ->
        ticket_facts(row, epic_key, feature_records, available?, opts)
      end)

    identities = Map.new(rows, fn row -> {Document.identity_key(row.member.identity), row.id} end)
    members = Map.new(rows, &{&1.id, &1.member})
    ticket_ids = MapSet.new(rows, & &1.id)

    depends_on = depends_on_edges(rows, identities, members, health, available?)
    declared = declared_edges(rows, ticket_ids, gate_keys)
    containment = containment_edges(rows, identities)
    edges = ordered_edges(depends_on ++ declared ++ containment)

    dependency_pairs = blocker_pairs(depends_on)
    waves = Graph.waves(Enum.map(rows, & &1.id), dependency_pairs, facts)
    facts = apply_waves(facts, waves)

    progress_opts = Document.progress_opts(available?, reason, tracker)

    features =
      feature_records
      |> Map.values()
      |> Enum.sort_by(& &1["key"])
      |> Enum.map(&Map.put(&1, "epic", epic_key))
      |> Enum.map(&with_progress(&1, facts, epic_key, progress_opts))

    critical_path =
      Graph.critical_path(Enum.map(rows, & &1.id), dependency_pairs, facts,
        available?: available?,
        reason: reason
      )

    Document.document(
      %{
        build_order_id: Pack.build_order_id(metadata, selected),
        title: selected.root.title,
        repository: Document.repository(snapshot, selected.root.identity),
        root: Pack.root_record(selected, epic_key, metadata),
        now: now
      },
      %{
        "pack" => Sources.pack(metadata, "pack_not_loaded"),
        "tracker" => tracker,
        "progress" => Sources.progress(tracker, partial_reason(facts, available?, reason))
      },
      %{
        epics: [with_progress(epic, facts, epic_key, progress_opts)],
        features: features,
        lanes: lane_records(facts, progress_opts),
        tickets: facts,
        edges: edges,
        gates: gates,
        waves: waves,
        critical_path: critical_path,
        progress: Progress.aggregate(facts, progress_opts)
      }
    )
  end

  defp row(%Member{} = member, relations) do
    relation = Map.get(relations, Document.identifier(member), %{})
    %{member: member, relation: relation, id: ticket_id(member, relation)}
  end

  defp ticket_facts(row, epic_key, features, available?, opts) do
    member = row.member
    runtime = runtime_fact(opts, Document.identifier(member))
    status = ticket_status(member, runtime, available?)
    complexity = complexity(member)
    number = member_number(member)

    %{
      "id" => row.id,
      "number" => number,
      "title" => member.title,
      "url" => member.url,
      "kind" => kind(row.relation),
      "provenance" => provenance(row.relation, member),
      "epic" => epic_key,
      "feature" => Pack.feature_key(member, row.relation, features),
      "lane" => lane_key(member),
      "phase" => phase_key(member),
      "wave" => 1,
      "complexity" => complexity,
      "points" => points(complexity),
      "estimate_hours" => estimate_hours(number, complexity, opts),
      "status" => status,
      "progress_percent" => progress_percent(member, status, runtime),
      "started_at" => runtime["started_at"],
      "ended_at" => runtime["ended_at"]
    }
  end

  defp depends_on_edges(rows, identities, members, health, available?) do
    rows
    |> Enum.flat_map(&dependency_edges(&1, identities, members, health, available?))
    |> Enum.reject(&is_nil/1)
  end

  defp dependency_edges(row, identities, members, health, available?) do
    Enum.map(row.member.dependencies, fn dependency ->
      from = identities[Document.identity_key(dependency.blocker_identity)]
      blocker = from && members[from]

      if valid_edge?(row, from, blocker) do
        # `from` depends on `to`, matching the contract fixture's direction:
        # the dependent ticket is the edge source and its blocker the target.
        %{
          "from" => row.id,
          "to" => from,
          "kind" => "depends_on",
          "state" => dependency_state(blocker, available?, health),
          "source" => dependency_source(dependency)
        }
      end
    end)
  end

  defp valid_edge?(_row, nil, _blocker), do: false
  defp valid_edge?(_row, _from, nil), do: false
  defp valid_edge?(row, from, _blocker), do: from != row.id

  defp blocker_pairs(depends_on) do
    Enum.map(depends_on, fn edge -> {edge["to"], edge["from"]} end)
  end

  defp dependency_state(%Member{draft?: true}, _available?, _health), do: "unknown"
  defp dependency_state(_blocker, false, _health), do: "unknown"

  defp dependency_state(%Member{lifecycle: lifecycle}, true, health) do
    case EdgeState.classify(lifecycle, health) do
      :cleared -> "cleared"
      :blocking -> "blocking"
      :terminal_unsatisfied -> "terminal_unsatisfied"
      _unknown -> "unknown"
    end
  end

  defp dependency_source(%Dependency{kind: :native, url: url}) when is_binary(url), do: "tracker"
  defp dependency_source(_dependency), do: "pack"

  defp declared_edges(rows, ticket_ids, gate_keys) do
    Enum.flat_map(rows, fn row ->
      declared_relations(row) ++ declared_gates(row, gate_keys)
    end)
    |> Enum.filter(fn edge -> edge["kind"] == "gates" or MapSet.member?(ticket_ids, edge["to"]) end)
  end

  defp declared_relations(row) do
    Enum.flat_map(~w(serializes_with suggested_after contains), fn kind ->
      row.relation
      |> Map.get(kind, [])
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.map(fn target ->
        %{"from" => row.id, "to" => target, "kind" => kind, "state" => nil, "source" => "pack"}
      end)
    end)
  end

  defp declared_gates(row, gate_keys) do
    row.relation
    |> Map.get("external_gates", [])
    |> List.wrap()
    |> Enum.filter(fn key -> is_binary(key) and MapSet.member?(gate_keys, key) end)
    |> Enum.map(fn key ->
      %{"from" => row.id, "to" => key, "kind" => "gates", "state" => nil, "source" => "pack"}
    end)
  end

  defp containment_edges(rows, identities) do
    Enum.flat_map(rows, fn row ->
      case identities[Document.identity_key(row.member.parent_identity)] do
        nil ->
          []

        parent when parent == row.id ->
          []

        parent ->
          [
            %{
              "from" => parent,
              "to" => row.id,
              "kind" => "contains",
              "state" => nil,
              "source" => "tracker"
            }
          ]
      end
    end)
  end

  defp ordered_edges(edges) do
    edges
    |> Enum.uniq_by(&{&1["kind"], &1["from"], &1["to"]})
    |> Enum.sort_by(&{&1["kind"], &1["from"], &1["to"]})
  end

  defp apply_waves(facts, waves) do
    index = for wave <- waves, id <- wave["tickets"], into: %{}, do: {id, wave["index"]}
    Enum.map(facts, fn fact -> Map.put(fact, "wave", Map.get(index, fact["id"], 1)) end)
  end

  defp with_progress(record, facts, epic_key, opts) do
    own =
      case record["key"] do
        ^epic_key -> facts
        key -> Enum.filter(facts, &(&1["feature"] == key))
      end

    Map.put(record, "progress", Progress.aggregate(own, opts))
  end

  defp lane_records(facts, opts) do
    facts
    |> Enum.map(& &1["lane"])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort_by(&lane_sort_key/1)
    |> Enum.with_index()
    |> Enum.map(fn {lane, index} ->
      own = Enum.filter(facts, &(&1["lane"] == lane))

      %{
        "key" => lane,
        "title" => Metadata.lane_label(lane),
        "label" => "build-lane:" <> lane,
        "icon" => nil,
        "hue" => nil,
        "order" => index,
        "progress" => Progress.aggregate(own, opts)
      }
    end)
  end

  defp lane_sort_key(lane) do
    case Enum.find_index(Metadata.lanes(), &(&1 == lane)) do
      nil -> {1, lane}
      index -> {0, index}
    end
  end

  defp partial_reason(facts, available?, reason) do
    cond do
      not available? -> reason
      Enum.any?(facts, &(&1["status"] == "unknown")) -> "partial_read"
      true -> nil
    end
  end

  defp ticket_id(member, relation) do
    cond do
      is_binary(relation["id"]) and relation["id"] != "" -> relation["id"]
      is_binary(Document.identifier(member)) -> Document.identifier(member)
      true -> "ticket-" <> Integer.to_string(:erlang.phash2(member.title))
    end
  end

  defp kind(relation) do
    case Map.get(relation, "kind") do
      kind when kind in @ticket_kinds -> kind
      _missing -> "executable"
    end
  end

  defp provenance(relation, %Member{draft?: draft?}) do
    case Map.get(relation, "provenance") do
      value when value in @provenances -> value
      _missing -> if(draft?, do: "planned", else: "unknown")
    end
  end

  defp member_number(%Member{draft?: true}), do: nil

  defp member_number(%Member{identity: %TrackerIdentity{identifier: identifier}}),
    do: Document.number_or_nil(identifier)

  defp member_number(_member), do: nil

  defp complexity(%Member{metadata: %Metadata{complexity: complexity}})
       when is_integer(complexity) and complexity in 1..5,
       do: complexity

  defp complexity(_member), do: nil

  defp points(complexity) when is_integer(complexity) do
    case FeatureStats.points(complexity) do
      points when is_integer(points) -> points
      _unknown -> nil
    end
  end

  defp points(_complexity), do: nil

  defp estimate_hours(number, complexity, opts) do
    overrides =
      case Keyword.get(opts, :estimates) do
        %{} = estimates -> estimates
        _missing -> %{}
      end

    case is_integer(number) && Map.get(overrides, number) do
      hours when is_number(hours) -> hours
      _missing -> Estimates.default_hours(complexity)
    end
  end

  defp lane_key(%Member{metadata: %Metadata{lane: lane}}) when is_binary(lane), do: lane
  defp lane_key(_member), do: nil

  defp phase_key(%Member{metadata: %Metadata{phase: phase}}) when is_integer(phase), do: phase
  defp phase_key(_member), do: nil

  defp runtime_fact(opts, identifier) when is_binary(identifier) do
    case Keyword.get(opts, :runtime) do
      %{} = runtime ->
        case Map.get(runtime, identifier) do
          %{} = fact -> fact
          _missing -> %{}
        end

      _missing ->
        %{}
    end
  end

  defp runtime_fact(_opts, _identifier), do: %{}

  defp ticket_status(%Member{draft?: true}, _runtime, _available?), do: "planned"

  defp ticket_status(member, runtime, true) do
    case runtime["status"] do
      status when status in ~w(planned queued running open closed done failed not_planned unknown) -> status
      _missing -> Document.lifecycle_status(member.lifecycle)
    end
  end

  defp ticket_status(_member, _runtime, false), do: "unknown"

  defp progress_percent(_member, "done", _runtime), do: 100
  defp progress_percent(_member, status, _runtime) when status in ["failed", "not_planned"], do: 0
  defp progress_percent(_member, status, _runtime) when status in ["planned", "unknown"], do: nil

  defp progress_percent(_member, _status, %{"progress_percent" => value})
       when is_integer(value) and value in 0..100,
       do: value

  defp progress_percent(%Member{activity: %{progress: value}}, _status, _runtime) when is_integer(value),
    do: value

  defp progress_percent(_member, _status, _runtime), do: nil
end
