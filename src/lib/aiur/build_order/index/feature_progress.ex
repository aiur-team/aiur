defmodule Aiur.BuildOrder.Index.FeatureProgress do
  @moduledoc "Aggregates feature progress from indexed rows and local Build Order manifests."
  alias Aiur.BuildOrder.{Features.RootImportMapping, Metadata}

  @spec compute(map(), map(), map(), boolean(), integer()) :: map()
  def compute(parts, all, features, complete?, now) do
    {packs, packs_available?} = packs(parts[:packs])
    packs = Enum.map(packs, &normalize_pack/1)

    values =
      for {slug, feature} <- features, epic <- feature.epics, into: %{} do
        epic_key = epic_key(epic)
        pack_set = Enum.filter(packs, &(&1.feature == slug))
        context = %{parts: parts, all: all, slug: slug, feature: feature, epic: epic, packs: pack_set, packs_available?: packs_available?, complete?: complete?, now: now}
        {epic_key, epic_progress(context)}
      end

    registry_known? = match?({:ok, _registry}, parts[:features])
    extras = if registry_known?, do: sum_extras(values)
    %{features: values, observed_at: now, plan_version: common_version(values), extras: extras, reason: if(registry_known?, do: nil, else: "states unavailable · planned count unavailable")}
  end

  defp epic_progress(context) do
    %{parts: parts, all: all, epic: epic, packs: pack_set, packs_available?: packs_available?, complete?: complete?, now: now} = context
    key = epic_key(epic)
    lane = epic_lane(key, pack_set, context.slug, context.feature)
    {lane_packs, members, rows, workstream} = epic_data(key, lane, pack_set, all)
    ci_known? = complete? and source_ok?(parts[:now])
    states = row_counts(rows, complete?, ci_known?)
    plan = plan_counts(members, rows, lane_packs, complete?, packs_available?)
    root_members = root_members(parts, context, key, complete?)
    plan = if root_members == :unknown, do: plan, else: Map.merge(plan, %{unpublished: 0, root_total: length(root_members)})
    root_counts = if is_list(root_members), do: root_row_counts(root_members, parts[:history], all, complete?, ci_known?)

    progress_metadata(context, lane_packs, members, workstream, plan, ci_known?, root_members)
    |> Map.merge(%{
      closed: if(root_counts, do: root_counts.closed, else: states.closed),
      open: if(root_counts, do: root_counts.open, else: states.open),
      ci_wait: if(root_counts, do: root_counts.ci_wait, else: states.ci_wait),
      unpublished: plan.unpublished,
      total: if(is_list(root_members), do: length(root_members), else: total_count(states, plan.unpublished, complete?, ci_known?)),
      extras: plan.extras,
      reason: progress_reason(root_counts, complete?, ci_known?, plan.unpublished, packs_available?),
      observed_at: now
    })
  end

  defp root_row_counts(members, history, all, complete?, ci_known?) do
    history_rows = history_member_rows(members, history)
    indexed_rows = Enum.map(members, &all[to_string(&1)])
    rows_known? = complete? and is_list(history_rows) and Enum.all?(history_rows, &known_history_lifecycle?/1)
    ci_known? = ci_known? and Enum.all?(indexed_rows, &is_map/1)
    ci_wait_ids = indexed_rows |> Enum.filter(&(is_map(&1) and ci_wait_row?(&1))) |> MapSet.new(& &1.num)

    %{
      closed: if(rows_known?, do: Enum.count(history_rows, &history_closed?/1)),
      open: if(rows_known?, do: Enum.count(members, &open_history_member?(history, &1, ci_wait_ids))),
      ci_wait: if(ci_known?, do: Enum.count(indexed_rows, &ci_wait_row?/1))
    }
  end

  defp history_member_rows(members, {:ok, %{rows: rows}}), do: Enum.map(members, &Map.get(rows, &1))
  defp history_member_rows(_members, _unavailable), do: :unknown

  defp open_history_member?({:ok, %{rows: rows}}, member, ci_wait_ids) do
    case Map.get(rows, member) do
      %{lifecycle: %{state: :open}} -> member not in ci_wait_ids
      _row -> false
    end
  end

  defp open_history_member?(_history, _member, _ci_wait_ids), do: false
  defp known_history_lifecycle?(%{lifecycle: %{state: state}}), do: state in [:open, :closed]
  defp known_history_lifecycle?(_row), do: false
  defp history_closed?(%{lifecycle: %{state: :closed}}), do: true
  defp history_closed?(_row), do: false

  defp closed_status?(status), do: status in ["done", "failed", "not_planned", "closed"]
  defp ci_wait_row?(row), do: row.sec == "now" and get_in(row, [:agent, :state]) == "ci_wait" and not closed_status?(row.status)

  defp epic_data(key, lane, pack_set, all) do
    lane_packs = if lane == :all, do: pack_set, else: Enum.filter(pack_set, &pack_has_lane?(&1, lane))
    members = if lane == :all, do: Enum.flat_map(lane_packs, & &1.members), else: Enum.flat_map(lane_packs, &lane_members(&1, lane))
    rows = Enum.filter(all, fn {_id, row} -> row.epic == key end)
    workstream = Enum.find_value(lane_packs, fn pack -> pack.workstreams[lane] end)
    {lane_packs, members, rows, workstream}
  end

  defp lane_members(pack, lane), do: Enum.filter(pack.members, &(&1.lane == lane))

  defp progress_metadata(context, lane_packs, members, workstream, plan, ci_known?, root_members) do
    %{parts: parts, slug: slug, feature: feature, epic: epic, packs: pack_set, packs_available?: packs_available?, complete?: complete?} = context

    %{
      feature: slug,
      label: epic_label(epic),
      wave: feature_wave(feature, workstream, parts, root_members),
      summary: feature[:summary] || get_workstream(workstream, "summary"),
      icon: feature[:icon] || get_workstream(workstream, "icon"),
      code: feature[:code] || get_workstream(workstream, "code") || member_code(members),
      plan_version: plan_version(lane_packs),
      root_number: first_value(lane_packs, :root) || root_number_from_slug(slug),
      root_title: first_value(pack_set, :root_title),
      start_date: first_value(lane_packs, :start_date) || root_start_date(parts[:history], slug) || feature_start(feature[:from]),
      reason: reason(complete?, ci_known?, not is_nil(plan.unpublished) and packs_available?)
    }
  end

  defp feature_wave(feature, workstream, parts, root_members),
    do: normalize_wave(feature[:wave]) || normalize_wave(get_workstream(workstream, "wave")) || normalize_wave(get_workstream(workstream, "phase")) || member_phase_wave(parts, root_members)

  defp member_phase_wave(_parts, :unknown), do: nil

  defp member_phase_wave(parts, members) do
    case parts[:history] do
      {:ok, %{rows: rows}} ->
        phases =
          members
          |> Enum.map(&Map.get(rows, &1))
          |> Enum.filter(&is_map/1)
          |> Enum.map(&Metadata.parse(&1.labels).phase)
          |> Enum.reject(&(&1 == :unphased))
          |> Enum.uniq()

        case phases do
          [phase] -> normalize_wave(phase)
          _ -> nil
        end

      _unavailable ->
        nil
    end
  end

  defp root_number_from_slug("bo-" <> raw) do
    case Integer.parse(raw) do
      {number, ""} when number > 0 -> number
      _invalid -> nil
    end
  end

  defp root_number_from_slug(_slug), do: nil

  defp root_start_date({:ok, %{rows: rows}}, "bo-" <> raw) do
    with {number, ""} when number > 0 <- Integer.parse(raw),
         %{created_at: %DateTime{} = created_at} <- Map.get(rows, number) do
      feature_start(created_at)
    else
      _unknown -> nil
    end
  end

  defp root_start_date(_history, _slug), do: nil

  defp get_workstream(nil, _key), do: nil
  defp get_workstream(workstream, key), do: workstream[key] || workstream[String.to_atom(key)]
  defp epic_label(%{label: label}), do: label
  defp epic_label(_epic), do: nil

  defp sum_extras(values) do
    if Enum.all?(values, fn {_key, value} -> is_integer(value.extras) end) do
      Enum.reduce(values, 0, fn {_key, value}, sum -> sum + value.extras end)
    end
  end

  defp row_counts(rows, complete?, ci_known?) do
    closed = Enum.count(rows, fn {_id, row} -> row.status in ["done", "failed", "not_planned", "closed"] end)
    ci_wait = Enum.count(rows, fn {_id, row} -> row.sec == "now" and get_in(row, [:agent, :state]) == "ci_wait" and row.status not in ["done", "failed", "not_planned", "closed"] end)
    open = length(rows) - closed - ci_wait

    %{closed: if(complete?, do: closed), open: if(complete?, do: open), ci_wait: if(ci_known?, do: ci_wait)}
  end

  defp plan_counts(members, rows, lane_packs, complete?, packs_available?) do
    known? = lane_packs != [] and Enum.all?(lane_packs, & &1.complete?)
    unpublished = if known? and packs_available?, do: max(length(members) - Enum.count(members, &is_integer(&1.number)), 0)

    extras =
      if known? and packs_available? and complete? do
        planned_numbers = members |> Enum.map(& &1.number) |> Enum.filter(&is_integer/1) |> MapSet.new()
        published_numbers = rows |> Enum.map(fn {id, _row} -> id_number(id) end) |> Enum.reject(&is_nil/1) |> MapSet.new()
        MapSet.difference(published_numbers, planned_numbers) |> MapSet.size()
      end

    %{unpublished: unpublished, extras: extras}
  end

  defp root_members(parts, %{slug: "bo-" <> root, feature: feature}, key, complete?) do
    with {number, ""} when number > 0 <- Integer.parse(root),
         {:ok, registry} <- parts[:features],
         true <- registry.health.state == :healthy,
         true <- complete?,
         {:ok, %{rows: history_rows, repository: repository}} <- parts[:history],
         %{features: features} <- registry,
         %{slug: slug} <- features["bo-#{number}"],
         true <- slug == "bo-#{number}" do
      history_rows
      |> Enum.filter(fn {_member, row} -> root_member?(row, number, repository) end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.filter(&lane_key(number, history_rows[&1], key, feature))
    else
      _unknown -> :unknown
    end
  end

  defp root_members(_parts, _context, _key, _complete?), do: :unknown

  defp root_member?(%{parent: %{number: root} = parent}, root, repository), do: RootImportMapping.same_repository?(parent, repository)
  defp root_member?(_row, _root, _repository), do: false

  defp lane_key(root, row, key, feature) do
    root_key = RootImportMapping.key(root, :unassigned)
    sole_root_epic? = key == root_key and Enum.map(feature.epics, &epic_key/1) == [root_key]

    case row do
      %{labels: labels} -> sole_root_epic? or RootImportMapping.key(root, RootImportMapping.lane(root, %{labels: labels})) == key
      _ -> RootImportMapping.key(root, :unassigned) == key
    end
  end

  defp total_count(%{closed: closed, open: open, ci_wait: ci_wait}, unpublished, complete?, ci_known?) do
    if complete? and ci_known? and is_integer(unpublished), do: closed + open + ci_wait + unpublished
  end

  defp normalize_pack(pack) when is_map(pack) do
    manifest = pack[:manifest] || pack[:metadata] || %{}
    root = root_number(pack, manifest)
    workstreams = workstreams(manifest)
    members = normalize_members(pack, manifest, root, workstreams)
    Map.merge(pack, normalized_pack_fields(pack, manifest, root, workstreams, members))
  end

  defp normalize_pack(pack), do: pack

  defp packs(value) when is_list(value), do: {value, true}
  defp packs({:ok, value}) when is_list(value), do: {value, true}
  defp packs(_unavailable), do: {[], false}

  defp normalized_pack_fields(pack, manifest, root, workstreams, members) do
    %{
      root: root,
      feature: pack_feature(pack, root),
      workstreams: workstreams,
      members: members,
      complete?: Map.get(pack, :complete?, is_map(manifest)),
      version: pack_version(pack, manifest),
      root_title: pack_title(pack, manifest),
      start_date: get_in(manifest, ["github_root", "created_at"])
    }
  end

  defp pack_feature(pack, root), do: pack[:feature] || if(is_integer(root), do: RootImportMapping.slug(root))

  defp root_number(pack, manifest), do: pack[:root] || pack[:root_number] || manifest["root_number"] || get_in(manifest, ["github_root", "number"])

  defp normalize_members(pack, manifest, root, workstreams) do
    tickets = pack[:tickets] || Map.get(manifest, "tickets", [])
    Enum.map(tickets, &normalize_member(&1, root, workstreams))
  end

  defp pack_version(pack, manifest), do: pack[:version] || manifest["version"] || manifest["updated_at"] || plan_digest(pack[:content_hash])
  defp pack_title(pack, manifest), do: pack[:title] || manifest["title"] || get_in(manifest, ["github_root", "title"])

  defp workstreams(manifest) do
    manifest
    |> Map.get("workstreams", [])
    |> Map.new(fn row -> {lane_id(row), row} end)
  end

  defp lane_id(row), do: to_string(row["id"] || row["lane"] || row["key"] || "unassigned")

  defp normalize_member(ticket, root, workstreams) do
    lane = ticket_lane(ticket) |> normalize_lane(workstreams, root)
    %{id: ticket_id(ticket), number: ticket_number(ticket), lane: lane}
  end

  defp ticket_lane(ticket), do: Map.get(ticket, :lane) || ticket["lane"] || ticket["workstream"] || "unassigned"
  defp ticket_id(ticket), do: Map.get(ticket, :id) || ticket["id"]

  defp normalize_lane(lane, workstreams, root) do
    valid_lane? = lane != "unassigned" and (map_size(workstreams) == 0 or Map.has_key?(workstreams, lane))
    valid_lane? = valid_lane? and (not is_integer(root) or byte_size(RootImportMapping.key(root, lane)) <= 64)
    if valid_lane?, do: lane, else: :unassigned
  end

  defp epic_key(%{key: key}), do: key
  defp epic_key(key) when is_binary(key), do: key

  defp ticket_number(%{number: number}) when is_integer(number) and number > 0, do: number
  defp ticket_number(%{"ticket" => number}) when is_integer(number) and number > 0, do: number
  defp ticket_number(%{"github" => %{"number" => number}}) when is_integer(number) and number > 0, do: number
  defp ticket_number(_), do: nil

  defp epic_lane(epic_key, packs, slug, feature) do
    Enum.find_value(packs, fn pack ->
      lane = pack_lane(pack, epic_key)
      if lane && pack_has_lane?(pack, lane), do: lane
    end) || imported_lane(epic_key, slug) || root_pack_lane(epic_key, packs, slug, feature) || :unassigned
  end

  defp root_pack_lane(epic_key, packs, "bo-" <> root, feature) do
    with {number, ""} when number > 0 <- Integer.parse(root),
         true <- epic_key == RootImportMapping.key(number, :unassigned),
         true <- packs != [],
         true <- Enum.map(feature.epics, &epic_key/1) == [epic_key] do
      :all
    else
      _no_root_pack -> nil
    end
  end

  defp root_pack_lane(_epic_key, _packs, _slug, _feature), do: nil

  defp imported_lane(epic_key, "bo-" <> root) do
    with {number, ""} <- Integer.parse(root),
         prefix = RootImportMapping.key(number, :unassigned) <> "-",
         true <- String.starts_with?(epic_key, prefix) do
      case String.replace_prefix(epic_key, prefix, "") do
        "" -> nil
        lane -> lane
      end
    else
      _ -> nil
    end
  end

  defp imported_lane(_epic_key, _slug), do: nil

  defp pack_has_lane?(_pack, :all), do: true
  defp pack_has_lane?(pack, lane), do: Enum.any?(pack.members, &(&1.lane == lane))

  defp pack_lane(pack, epic_key), do: Enum.find_value(pack.members, &member_lane(&1, pack.root, epic_key))
  defp member_lane(member, root, key), do: if(RootImportMapping.key(root, member.lane) == key, do: member.lane)

  defp normalize_wave(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_wave(value) when is_binary(value), do: value
  defp normalize_wave(_), do: nil

  defp member_code(members) do
    members
    |> Enum.find_value(fn %{id: id} -> if is_binary(id), do: Regex.run(~r/^(.*?)-C[0-9]+(?:-|$)/, id, capture: :all_but_first) end)
    |> case do
      [code] -> code
      _ -> nil
    end
  end

  defp feature_start(%DateTime{} = date), do: DateTime.to_date(date) |> Date.to_iso8601()
  defp feature_start(_), do: nil

  defp plan_digest(hash) when is_binary(hash), do: "sha256:" <> Base.encode16(hash, case: :lower)
  defp plan_digest(_), do: nil

  defp id_number(id) when is_binary(id) do
    case Integer.parse(id) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp id_number(number) when is_integer(number), do: number
  defp id_number(_), do: nil

  defp first_value(packs, key), do: Enum.find_value(packs, &Map.get(&1, key))
  defp plan_version([]), do: nil

  defp plan_version(packs) do
    versions = packs |> Enum.map(& &1.version) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    if length(versions) == 1, do: hd(versions)
  end

  defp common_version(values), do: values |> Enum.map(fn {_key, value} -> value.plan_version end) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> List.first()
  defp source_ok?(%{source: %{state: "ok"}}), do: true
  defp source_ok?(_), do: false

  defp prepend_reason(nil, value), do: value
  defp prepend_reason(reason, value), do: value <> " · " <> reason

  defp progress_reason(%{closed: nil}, complete?, ci_known?, unpublished, packs_available?),
    do: prepend_reason(reason(complete?, ci_known?, not is_nil(unpublished) and packs_available?), "states unavailable")

  defp progress_reason(_root_counts, complete?, ci_known?, unpublished, packs_available?),
    do: reason(complete?, ci_known?, not is_nil(unpublished) and packs_available?)

  defp reason(states?, ci?, plan?) do
    [if(states?, do: nil, else: "states unavailable"), if(ci?, do: nil, else: "CI state unknown"), if(plan?, do: nil, else: "planned count unavailable")]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> case do
      "" -> nil
      value -> value
    end
  end
end
