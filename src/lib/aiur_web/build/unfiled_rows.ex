defmodule AiurWeb.Build.UnfiledRows do
  @moduledoc "Read-only planning-pack rows, source health and aliases to filed tickets."
  alias AiurWeb.BuildOrder.PlanningSource
  @part ~r/\A[A-Za-z0-9._-]{1,64}\z/

  @spec build(map(), keyword()) :: %{rows: [map()], aliases: map(), source: map()}
  def build(context, opts \\ []) do
    loaded = Keyword.get(opts, :loader, &PlanningSource.load_pack_results/0).()
    {items, skipped} = collect(loaded.packs)
    aliases = Map.new(for item <- items, is_integer(item.ticket.number), do: {item.ticket.number, item.id})
    rows = items |> Enum.filter(&is_nil(&1.ticket.number)) |> rows(items, context)
    %{rows: rows, aliases: aliases, source: source(loaded, skipped, context.now)}
  rescue
    _error -> unavailable(context.now)
  catch
    _kind, _reason -> unavailable(context.now)
  end

  defp unavailable(now), do: %{rows: [], aliases: %{}, source: %{state: "unavailable", observed_at: now, reason: "planning packs could not be read"}}

  defp collect(packs) do
    {items, skipped, _seen} =
      packs
      |> Enum.reject(& &1.completed)
      |> Enum.reduce({[], [], MapSet.new()}, fn pack, {items, skipped, seen} ->
        key = pack_key(pack)
        duplicate? = MapSet.member?(seen, key)
        {good, bad} = Enum.split_with(pack.tickets, &(not duplicate? and valid?(key) and valid?(&1.id)))
        entries = Enum.map(good, &%{id: "pack:#{key}/#{&1.id}", ticket: &1, pack: pack})
        {items ++ entries, skipped ++ Enum.map(bad, fn _ticket -> display_path(pack) end), MapSet.put(seen, key)}
      end)

    {items, skipped}
  end

  defp valid?(value), do: is_binary(value) and value not in [".", ".."] and Regex.match?(@part, value)
  defp pack_key(%{build_order_id_explicit?: true, build_order_id: id}), do: id |> String.split(":") |> List.last()
  defp pack_key(pack), do: "p" <> binary_part(Base.encode16(:crypto.hash(:sha256, pack.path), case: :lower), 0, 8)
  defp phase(%{phase: phase}) when is_integer(phase) and phase >= 0, do: phase
  defp phase(_ticket), do: nil

  defp rows(unfiled, items, context) do
    phases = unfiled |> Enum.map(&phase(&1.ticket)) |> Enum.uniq() |> Enum.sort_by(&{is_nil(&1), &1})
    ranks = phases |> Enum.with_index(1) |> Map.new()
    lookup = Map.new(items, &{{&1.pack.path, &1.ticket.id}, &1})
    rows = unfiled |> Enum.sort_by(&ranks[phase(&1.ticket)]) |> Enum.with_index(1) |> Enum.map(fn {item, position} -> row(item, lookup, ranks, position, context) end)
    children = Enum.reduce(rows, %{}, fn row, children -> Enum.reduce(row.deps, children, &Map.update(&2, &1, [row.id], fn ids -> ids ++ [row.id] end)) end)
    Enum.map(rows, &Map.put(&1, :children, Map.get(children, &1.id, [])))
  end

  defp row(item, lookup, ranks, position, context) do
    ticket = item.ticket
    dependencies = Enum.map(ticket.depends_on, &dependency(lookup[{item.pack.path, &1}], context))
    deps = Enum.reject(dependencies, &is_nil/1)
    states = Map.new(deps, fn id -> {id, if(cleared?(id, context.done_numbers), do: "cleared", else: "blocking")} end)
    cx = if is_integer(ticket.complexity) and ticket.complexity in 1..5, do: ticket.complexity

    %{
      id: item.id,
      num: nil,
      qpos: nil,
      start: nil,
      end: nil,
      created: nil,
      agent: nil,
      pr: nil,
      override: nil,
      est: nil,
      pct: 0,
      start_src: "unknown",
      title: ticket.title,
      type: "feature",
      epic: if(MapSet.member?(context.epics, ticket.lane), do: ticket.lane),
      feature: nil,
      also: [],
      cx: cx,
      pts: if(cx, do: Enum.at([1, 2, 3, 5, 8], cx - 1)),
      sec: "plan",
      status: "queued",
      ord: context.max_ord + position,
      wave: context.max_wave + ranks[phase(ticket)],
      deps: deps,
      deps_missing: Enum.count(dependencies, &is_nil/1),
      dep_states: states,
      cue: %{held: nil, promoted: nil, wait: nil, waitAny: "blocking" in Map.values(states), failed: nil, blockedChain: false, unknown: false},
      added: false,
      src: %{kind: "pack", path: display_path(item.pack), wave: phase(ticket)},
      was: nil
    }
  end

  defp dependency(nil, _context), do: nil
  defp dependency(%{ticket: %{number: nil}, id: id}, _context), do: id
  defp dependency(%{ticket: %{number: number}}, context), do: if(MapSet.member?(context.filed_numbers, number), do: to_string(number))
  defp cleared?("pack:" <> _rest, _done), do: false
  defp cleared?(id, done), do: MapSet.member?(done, String.to_integer(id))
  defp display_path(%{source: :workspace, path: path}), do: ".aiur/build_orders/" <> Path.basename(path)
  defp display_path(%{source: :state, path: path}), do: "builds/" <> Path.basename(Path.dirname(path)) <> "/build-order.json"
  defp display_path(%{path: path}) when is_binary(path), do: Path.basename(path)
  defp display_path(_source), do: "invalid pack path"

  defp source(loaded, skipped, now) do
    reasons = if loaded.failed == [], do: [], else: ["#{length(loaded.failed)} of #{loaded.configured} planning packs could not be read: #{paths(loaded.failed)}"]
    reasons = if skipped == [], do: reasons, else: reasons ++ ["#{length(skipped)} planning-pack items could not be read: #{skipped |> Enum.uniq() |> Enum.join(", ")}"]
    reason = if reasons == [], do: nil, else: Enum.join(reasons, "; ")

    cond do
      loaded.configured == 0 -> %{state: "disabled", observed_at: now, reason: "no_pack_configured"}
      reason -> %{state: "unavailable", observed_at: now, reason: reason}
      true -> %{state: "ok", observed_at: now, reason: nil}
    end
  end

  defp paths(failed), do: failed |> Enum.map(&display_path/1) |> Enum.uniq() |> Enum.join(", ")
end
