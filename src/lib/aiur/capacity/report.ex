defmodule Aiur.Capacity.Report do
  @moduledoc """
  The capacity policy's validation metrics (plan 7881, section 8), computed from
  the capacity sample log and the `dispatch` telemetry points.

  Every metric carries its population and how many members could not be judged
  (`unknown`). A figure that was not recorded counts as unknown, never as zero.
  Dispatches are split into windows by the `agent.priority` in force, because a
  window under another priority is not comparable.
  """

  @type metric :: %{key: String.t(), label: String.t(), count: non_neg_integer(), population: non_neg_integer(), unknown: non_neg_integer(), items: [map()]}

  @doc """
  Builds the report from decoded sample lines (`Aiur.Capacity.SampleLog`) and
  dispatch points (`%{"timestamp" => iso, "attributes" => %{...}}`), keeping
  only those at or after `since`.
  """
  @spec build([map()], [map()], DateTime.t()) :: map()
  def build(samples, dispatches, %DateTime{} = since) do
    floor = DateTime.to_unix(since, :microsecond)
    samples = samples |> Enum.map(&Map.put(&1, "t", micros(&1["at"]))) |> Enum.filter(&(&1["t"] >= floor)) |> Enum.sort_by(& &1["t"])

    dispatches =
      dispatches
      |> Enum.filter(&(get_in(&1, ["attributes", "event"]) == "dispatch" and get_in(&1, ["attributes", "boundary"]) == "point"))
      |> Enum.map(&Map.merge(&1["attributes"], %{"at" => &1["timestamp"], "t" => micros(&1["timestamp"])}))
      |> Enum.filter(&(&1["t"] >= floor))
      |> Enum.sort_by(& &1["t"])

    %{
      since: DateTime.to_iso8601(since),
      samples: length(samples),
      dispatches: length(dispatches),
      windows: windows(dispatches),
      metrics: [
        reserve_broken(dispatches, samples),
        reserve_low_samples(samples),
        codex_share(dispatches),
        openrouter_other_allowed(dispatches),
        limit_exceeded(samples),
        unknown_as_number(samples)
      ]
    }
  end

  @doc "Plain-text rendering, one line per window and metric."
  @spec render(map()) :: String.t()
  def render(report) do
    header = "capacity report since #{report.since}: #{report.dispatches} dispatches, #{report.samples} samples"

    windows =
      Enum.map(report.windows, fn w ->
        "  window #{w.from} .. #{w.to}  agent.priority=#{w.priority}  codex #{w.codex}/#{w.dispatches} dispatches (#{percent(w.codex, w.dispatches)})"
      end)

    metrics =
      Enum.flat_map(report.metrics, fn m ->
        ["  #{m.label}: #{m.count} of #{m.population} (unknown #{m.unknown})" | Enum.map(m.items, &("    - " <> item_text(&1)))]
      end)

    Enum.join([header, "windows by agent.priority:" | windows] ++ ["metrics:" | metrics], "\n")
  end

  defp windows(dispatches) do
    dispatches
    |> Enum.chunk_by(&(&1["priority"] || "unknown"))
    |> Enum.map(fn chunk ->
      %{
        priority: List.first(chunk)["priority"] || "unknown",
        from: List.first(chunk)["at"],
        to: List.last(chunk)["at"],
        dispatches: length(chunk),
        codex: Enum.count(chunk, &(family(&1["backend"]) == "codex"))
      }
    end)
  end

  defp reserve_broken(dispatches, samples) do
    judged = Enum.map(dispatches, &{&1, row_before(samples, &1)})
    reserved = Enum.filter(judged, fn {_d, row} -> reserved?(row) end)
    broken = Enum.filter(reserved, fn {_d, row} -> at_or_below?(row) end)

    metric("reserve_broken", "worker dispatches that broke a reserve", broken, length(reserved), Enum.count(judged, fn {_d, row} -> unknown_reserve?(row) end), fn {d, row} ->
      %{at: d["at"], ticket: d["ticket"], backend: d["backend"], account: d["account"], figure: figure(row), reserve: row["reserve_percent"]}
    end)
  end

  defp reserve_low_samples(samples) do
    rows = for sample <- samples, row <- sample["accounts"] || [], reserved?(row), do: Map.put(row, "at", sample["at"])
    low = Enum.filter(rows, &at_or_below?/1)
    with_worker = Enum.filter(low, &((&1["running"] || 0) > 0))

    %{
      metric("reserve_low_with_worker", "reserved-account samples at or below reserve with a worker running", with_worker, length(low), Enum.count(rows, &is_nil(figure(&1))), fn row ->
        %{at: row["at"], backend: row["backend"], account: row["account"], figure: figure(row), reserve: row["reserve_percent"], running: row["running"]}
      end)
      | label: "reserved-account samples at or below reserve with a worker running (population: samples at or below reserve)"
    }
  end

  defp codex_share(dispatches) do
    codex = Enum.filter(dispatches, &(family(&1["backend"]) == "codex"))
    metric("codex_share", "codex dispatches / all coding dispatches", codex, length(dispatches), Enum.count(dispatches, &is_nil(&1["backend"])), nil)
  end

  defp openrouter_other_allowed(dispatches) do
    openrouter = Enum.filter(dispatches, &(family(&1["backend"]) == "openrouter"))
    unjudged = Enum.count(openrouter, &(not is_list(&1["candidates"])))
    broke = Enum.filter(openrouter, &other_allowed?/1)
    metric("openrouter_other_allowed", "openrouter dispatches while another source was allowed", broke, length(openrouter), unjudged, &%{at: &1["at"], ticket: &1["ticket"]})
  end

  defp limit_exceeded(samples) do
    periods =
      for(sample <- samples, source <- sample["sources"] || [], is_number(source["limit_usd"]), do: source)
      |> Enum.group_by(&{&1["backend"], &1["period"], &1["period_start"]})
      |> Enum.map(fn {{backend, period, start}, entries} ->
        spends = entries |> Enum.map(& &1["spend_usd"]) |> Enum.filter(&is_number/1)
        %{backend: backend, period: period, period_start: start, limit_usd: List.last(entries)["limit_usd"], spend_usd: Enum.max(spends, fn -> nil end)}
      end)

    over = Enum.filter(periods, &(is_number(&1.spend_usd) and &1.spend_usd > &1.limit_usd))
    metric("limit_exceeded", "source periods whose recorded spend passed its limit", over, length(periods), Enum.count(periods, &is_nil(&1.spend_usd)), & &1)
  end

  defp unknown_as_number(samples) do
    rows = for sample <- samples, row <- sample["accounts"] || [], row["freshness"] in ["unknown", "unavailable"], do: Map.put(row, "at", sample["at"])
    shown = Enum.filter(rows, &is_number(&1["remaining_percent"]))
    metric("unknown_as_number", "unknown readings shown as a number", shown, length(rows), 0, &%{at: &1["at"], backend: &1["backend"], account: &1["account"]})
  end

  defp metric(key, label, matched, population, unknown, item_fun) do
    items = if item_fun, do: Enum.map(matched, item_fun), else: []
    %{key: key, label: label, count: length(matched), population: population, unknown: unknown, items: items}
  end

  # The latest sample row for the dispatched backend and account at or before the dispatch.
  defp row_before(samples, dispatch) do
    key = {family(dispatch["backend"]), dispatch["account"] || "default"}

    samples
    |> Enum.take_while(&(&1["t"] <= dispatch["t"]))
    |> Enum.reverse()
    |> Enum.find_value(fn sample -> Enum.find(sample["accounts"] || [], &({&1["backend"], &1["account"] || "default"} == key)) end)
  end

  defp reserved?(row), do: is_map(row) and is_number(row["reserve_percent"]) and row["reserve_percent"] > 0
  defp unknown_reserve?(row), do: not is_map(row) or is_nil(row["reserve_percent"]) or (reserved?(row) and is_nil(figure(row)))
  defp at_or_below?(row), do: is_number(figure(row)) and figure(row) <= row["reserve_percent"]
  defp figure(row), do: row["projected_percent"] || row["remaining_percent"]

  defp other_allowed?(%{"candidates" => candidates}) when is_list(candidates),
    do: Enum.any?(candidates, &(is_map(&1) and &1["verdict"] == "allow" and family(&1["route"] || &1["backend"]) != "openrouter"))

  defp other_allowed?(_dispatch), do: false

  defp family(nil), do: nil
  defp family(backend), do: backend |> to_string() |> String.split(":", parts: 2) |> hd()

  # An unparseable time sorts before any `since`, so it is left out rather than misplaced.
  defp micros(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, dt, _offset} -> DateTime.to_unix(dt, :microsecond)
      _error -> -1
    end
  end

  defp micros(_at), do: -1

  defp percent(_part, 0), do: "n/a"
  defp percent(part, whole), do: "#{Float.round(part * 100 / whole, 1)}%"

  defp item_text(item), do: item |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{v}" end)
end
