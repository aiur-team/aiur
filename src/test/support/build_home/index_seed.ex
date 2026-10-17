defmodule Aiur.TestSupport.BuildHome.IndexSeed do
  @moduledoc "Temporary real-store inputs for the index parity tests and browser route."
  alias Aiur.BuildOrder.{EpicOverrides, Features, History, Index, Lifecycle}
  alias Aiur.TestSupport.BuildHome.{FixtureSource, IndexParts}

  def start(dataset, dir) do
    {:ok, data} = FixtureSource.full(dataset: dataset)
    settings = %{build_order: %{general_epics: IndexParts.general()}, tracker: %{github: %{label_prefix: "agent"}}}
    {:ok, history} = History.start_link(name: nil, repository: "example/aiur-fixture", state_dir: Path.join(dir, "history"), flush_ms: 60_000)

    {:ok, features} =
      Features.start_link(
        name: nil,
        state_dir: Path.join(dir, "features"),
        general_epics: IndexParts.general(),
        clock: fn -> dt(data["now"]) end,
        filesystem_sync_fun: fn -> :ok end,
        alert_fun: fn _, _, _ -> :ok end
      )

    override_name = Module.concat(__MODULE__, "Overrides#{System.unique_integer([:positive])}")
    {:ok, overrides} = EpicOverrides.start_link(name: override_name, repository: "example/aiur-fixture", state_dir: Path.join(dir, "overrides"), settings_fun: fn -> {:ok, settings} end)
    rows = Enum.flat_map(data["sections"], &elem(&1, 1))
    {:ok, _} = History.apply(Enum.map(rows, &event(&1, data["now"])), server: history)
    :ok = History.mark_complete(server: history)
    seed_features(features, data, rows)

    for {epic, members} <- Enum.group_by(Enum.filter(rows, &is_nil(&1["feature"])), & &1["epic"]), epic != "unsorted" do
      {:ok, _} = EpicOverrides.set(epic, Enum.map(members, & &1["num"]), %{actor: "cli:fixture", source: "cli:fixture"}, server: override_name)
    end

    opts = [
      history_opts: [server: history],
      features_opts: [server: features],
      overrides_opts: [server: override_name],
      settings_fun: fn -> {:ok, settings} end,
      repository_fun: fn -> {:ok, {"example", "aiur-fixture"}} end
    ]

    core = Index.read_core_parts(MapSet.new(~w(history health features overrides settings repository)a), opts)
    source = %{state: "ok", observed_at: data["now"], reason: nil}
    now = Enum.map(data["sections"]["now"], &facts(&1, ~w(id num sec status ord start start_src pct agent)))
    planned = Enum.map(data["sections"]["plan"], &facts(&1, ~w(id num sec status ord deps wave qpos cue)))
    nq = Enum.map(data["sections"]["nq"], &facts(&1, ~w(num sec status title created cx pts))) |> Enum.map(&Map.put(&1, :ord, &1.num))

    parts =
      Map.merge(core, %{
        catch_up: %{status: :ok, at: dt(data["now"])},
        now: %{rows: Map.new(now, &{&1.id, &1}), source: source},
        planned: %{rows: planned, source: source},
        not_queued: %{rows: nq, state: :ok, reasons: [], observed_at: dt(data["now"]), truncated?: false}
      })

    %{parts: parts, data: data, processes: [history, features, overrides], opts: opts}
  end

  def stop(seed), do: Enum.each(seed.processes, fn pid -> if Process.alive?(pid), do: GenServer.stop(pid) end)

  defp seed_features(server, data, rows) do
    meta = [server: server, actor: "cli:fixture", source: "cli:fixture"]

    for {slug, f} <- data["features"] do
      epics = Enum.map(f["epics"], fn key -> %{key: key, label: data["epics"][key]["label"]} end)
      {:ok, _} = Features.create(slug, %{label: f["label"], hue: f["hue"], epics: epics, from: dt(f["from"]), to: if(f["to"], do: dt(f["to"]), else: :none)}, meta)
      members = Enum.filter(rows, &(&1["feature"] == slug))
      {added, original} = Enum.split_with(members, & &1["added"])
      for row <- original, do: add_feature(slug, row, meta, epics)
      if get_in(f, ["stats", "baseline"]), do: Features.set_baseline(slug, meta)
      for row <- added, do: add_feature(slug, row, meta, epics)
    end

    for row <- rows, slug <- row["also"], do: {:ok, _} = Features.also(slug, [row["num"]], meta)
  end

  defp add_feature(slug, row, meta, epics) do
    # 24 frozen demo rows name a general epic for a feature owner; real stores require a feature epic.
    epic = if Enum.any?(epics, &(&1.key == row["epic"])), do: row["epic"], else: hd(epics).key
    {:ok, _} = Features.add(slug, [row["num"]], Keyword.put(meta, :epic, epic))
  end

  defp event(row, now) do
    closed? = row["sec"] == "hist"
    blocked_by = Enum.map(row["deps"], &%{owner: "example", repository: "aiur-fixture", number: String.to_integer(&1)})

    fields = %{
      title: row["title"],
      labels: labels(row),
      labels_complete: true,
      created_at: dt(row["created"]),
      lifecycle: %Lifecycle{state: if(closed?, do: :closed, else: :open), state_reason: if(closed?, do: reason(row["status"]), else: :none)},
      closed_at: if(closed?, do: dt(row["end"]), else: :none),
      blocked_by: blocked_by,
      blocked_by_complete: true,
      in_progress_at: start_time(row, "label"),
      dispatched_at: start_time(row, "dispatch"),
      agent_model: get_in(row, ["agent", "model"]) || :none,
      agent_effort: get_in(row, ["agent", "effort"]) || :none
    }

    %{number: row["num"], observed_at: dt(now), source: :backfill, fields: fields}
  end

  defp reason("done"), do: :completed
  defp reason("not_planned"), do: :not_planned
  defp reason(_), do: :unknown
  defp start_time(row, source), do: if(row["start_src"] == source, do: dt(row["start"]), else: :unknown)

  defp labels(row) do
    labels =
      case row["type"] do
        "feature" -> []
        "docs" -> ["documentation"]
        type -> [type]
      end

    if row["cx"], do: labels ++ ["complexity:#{row["cx"]}"], else: labels
  end

  defp facts(row, keys), do: row |> Map.take(keys) |> atom_keys()
  defp atom_keys(map) when is_map(map), do: Map.new(map, fn {k, v} -> {String.to_atom(k), atom_keys(v)} end)
  defp atom_keys(list) when is_list(list), do: Enum.map(list, &atom_keys/1)
  defp atom_keys(value), do: value
  defp dt(nil), do: :unknown
  defp dt(ms), do: DateTime.from_unix!(ms, :millisecond)
end
