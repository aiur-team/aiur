defmodule Aiur.BuildOrder.Features.LabelRules do
  @moduledoc "Pure feature-label reconciliation; rows carry registered_slugs and observation health."
  alias Aiur.BuildOrder.Features.FeatureData

  # ponytail: fixed two-minute settle window; configure only if real observations require tuning.
  @settle_ms 120_000
  @spec settle_ms() :: pos_integer()
  def settle_ms, do: @settle_ms

  @spec parse(term()) :: {:ok, String.t()} | :ignore
  def parse(label) when is_binary(label) do
    case String.downcase(label) do
      "feature:" <> slug -> if FeatureData.slug?(slug), do: {:ok, slug}, else: :ignore
      _ -> :ignore
    end
  end

  def parse(_), do: :ignore

  @spec entry(atom(), DateTime.t()) :: map()
  def entry(state, now), do: %{state: state, written_at: nil, seen_at: nil, attempts: 0, last_error: nil, failed_from: nil, queued_at: now}

  @spec reconcile_registry(map(), map(), DateTime.t()) :: map()
  def reconcile_registry(entries, owners, now \\ DateTime.utc_now()) do
    entries = Enum.reduce(entries, %{}, fn {{slug, n} = key, value}, acc -> reconcile_entry(acc, key, value, owners[n], slug, now) end)
    Enum.reduce(owners, entries, fn {n, owner}, acc -> Map.put_new(acc, {owner.feature, n}, initial_entry(owner, now)) end)
  end

  defp reconcile_entry(acc, key, %{state: state}, %{feature: slug} = owner, slug, now) when state in [:pending_unlabel, :unlabelled], do: Map.put(acc, key, entry(start_state(owner), now))
  defp reconcile_entry(acc, key, value, %{feature: slug}, slug, _now), do: Map.put(acc, key, value)
  defp reconcile_entry(acc, _key, %{state: state}, _owner, _slug, _now) when state in [:exempt, :held_backfill], do: acc

  defp reconcile_entry(acc, key, %{state: :unlabelled} = value, _owner, _slug, now) do
    if is_struct(value.written_at, DateTime) and DateTime.diff(now, value.written_at) > 86_400, do: acc, else: Map.put(acc, key, value)
  end

  defp reconcile_entry(acc, key, %{state: :failed, failed_from: :pending_unlabel} = value, _owner, _slug, _now), do: Map.put(acc, key, value)

  defp reconcile_entry(acc, key, %{state: state} = value, _owner, _slug, now) when state in [:labelled, :pending_label, :failed],
    do: Map.put(acc, key, %{value | state: :pending_unlabel, attempts: 0, queued_at: now})

  defp reconcile_entry(acc, key, value, _owner, _slug, _now), do: Map.put(acc, key, value)

  defp initial_entry(owner, now) do
    value = entry(start_state(owner), now)
    if value.state == :labelled, do: %{value | seen_at: owner[:joined_at] || now}, else: value
  end

  defp start_state(%{source: "backfill-agent"}), do: :held_backfill
  defp start_state(%{source: "import:" <> _}), do: :exempt
  defp start_state(%{source: "label:" <> _}), do: :labelled
  defp start_state(%{confirmed: false}), do: :exempt
  defp start_state(_), do: :pending_label

  @spec decide(map(), map() | nil, map(), DateTime.t()) :: [tuple()]
  def decide(%{labels: :unknown}, _owner, _entries, _now), do: []
  def decide(%{health: %{state: state}}, _owner, _entries, _now) when state != :healthy, do: []

  def decide(row, owner, entries, now) do
    slugs =
      row.labels
      |> Enum.flat_map(fn label ->
        case parse(label) do
          {:ok, slug} -> [slug]
          :ignore -> []
        end
      end)
      |> Enum.uniq()
      |> Enum.sort()

    {known, unknown} = Enum.split_with(slugs, &MapSet.member?(row.registered_slugs, &1))
    eligible = Enum.reject(known, &tombstone?(entries[{&1, row.number}]))
    unregistered = Enum.map(unknown, &{:unregistered, row.number, &1})
    presence = Enum.flat_map(known, &presence(row, owner, entries, &1))
    unregistered ++ presence ++ join(row, owner, eligible) ++ absence(row, entries, slugs, owner, now)
  end

  defp tombstone?(%{state: :failed, failed_from: :pending_unlabel}), do: true
  defp tombstone?(%{state: state}) when state in [:pending_unlabel, :unlabelled], do: true
  defp tombstone?(_), do: false

  defp presence(row, %{feature: slug}, entries, slug) do
    case entries[{slug, row.number}] do
      %{state: state} = value when state in [:pending_label, :labelled, :failed] -> [{:put, {slug, row.number}, %{value | state: :labelled, seen_at: row.observed_at, attempts: 0, last_error: nil}}]
      _ -> []
    end
  end

  defp presence(_row, _owner, _entries, _slug), do: []
  defp join(_row, _owner, []), do: []
  defp join(row, nil, [slug]), do: [{:add, slug, [row.number], metadata(row, slug, :labeled)}]
  defp join(row, nil, slugs), do: [{:conflict, row.number, slugs}]
  defp join(_row, %{feature: slug}, [slug]), do: []

  defp join(row, %{feature: other, source: "backfill-agent", confirmed: false}, [slug]) when slug != other,
    do: [{:add, slug, [row.number], Keyword.put(metadata(row, slug, :labeled), :move, true)}]

  defp join(row, owner, slugs) do
    if Enum.any?(slugs, &(&1 != owner.feature)), do: [{:conflict, row.number, Enum.sort(Enum.uniq([owner.feature | slugs]))}], else: []
  end

  defp absence(%{labels_complete: complete}, _entries, _slugs, _owner, _now) when complete != true, do: []

  defp absence(row, entries, slugs, owner, now) do
    Enum.flat_map(entries, fn {{slug, n} = key, value} ->
      if n == row.number and slug not in slugs, do: absent(row, owner, key, value, now), else: []
    end)
  end

  defp absent(_row, _owner, key, %{state: :pending_unlabel} = value, now), do: [{:put, key, %{value | state: :unlabelled, written_at: now}}]

  defp absent(row, %{feature: slug}, {slug, _n}, %{state: :labelled} = value, now) do
    reference = value.written_at || value.seen_at

    if is_struct(reference, DateTime) do
      deadline = DateTime.add(reference, @settle_ms, :millisecond)
      later_seen? = is_nil(value.seen_at) or DateTime.compare(row.observed_at, value.seen_at) == :gt

      cond do
        DateTime.compare(row.observed_at, deadline) == :gt and later_seen? -> [{:remove, slug, [row.number], metadata(row, slug, :unlabeled)}]
        DateTime.compare(now, deadline) != :gt -> [{:recheck, deadline, row.number}]
        true -> []
      end
    else
      []
    end
  end

  defp absent(_row, _owner, _key, _value, _now), do: []

  defp events(events) when is_list(events), do: events
  defp events(_), do: []

  defp metadata(row, slug, action) do
    event =
      row |> Map.get(:label_events, []) |> events() |> Enum.filter(&(&1.label == "feature:" <> slug and &1.action == action)) |> Enum.max_by(&DateTime.to_unix(&1.at, :microsecond), fn -> nil end)

    actor = if event && is_binary(event[:actor]) && FeatureData.source?("label:" <> event.actor), do: event.actor, else: "unknown"
    [source: "label:" <> actor, actor: actor, at: if(event, do: event.at, else: row.observed_at)]
  end
end
