defmodule AiurWeb.OperatorControlCenter.Analytics.Charts do
  @moduledoc """
  Pure inline-SVG chart builders for the analytics page — the house rendering
  style (no client charting library). Each function turns the analytics view
  model plus view state into a self-contained, theme-reactive `<svg>` string;
  colors reference CSS custom properties so light/dark switch without a redraw.
  """

  @w 760

  @doc "Stacked per-unit CPU over the run: daemon/executor baseline, selected unit tickets, and an aggregated remainder, under the machine ceiling."
  @spec cpu_stack(map(), MapSet.t()) :: String.t()
  def cpu_stack(model, selected) do
    %{series: series, window: %{start_ms: t0, end_ms: t1}, actors: actors, cpu_ceiling: ceiling} = model
    h = 300
    {ml, mr, mt, mb} = {44, 16, 14, 26}
    pw = @w - ml - mr
    ph = h - mt - mb
    units = Enum.filter(actors, &MapSet.member?(selected, &1.key))

    totals =
      Enum.map(series, fn s -> s.exec_cpu + s.other_cpu + Enum.sum(Enum.map(units, &Map.get(s.per, &1.key, 0.0))) end)

    vmax = Enum.max([ceiling | totals]) |> max(1)
    xf = fn t -> ml + (t - t0) / max(t1 - t0, 1) * pw end
    yf = fn v -> mt + ph - v / vmax * ph end

    layers =
      [{"var(--faint)", 0.5, fn s -> s.exec_cpu end}] ++
        Enum.map(units, fn u -> {scolor(u.color_i), 0.85, fn s -> Map.get(s.per, u.key, 0.0) end} end) ++
        [{"var(--muted)", 0.4, fn s -> s.other_cpu end}]

    ceiling_y = r2(yf.(ceiling))

    ceiling_mark =
      ~s|<line x1="#{ml}" x2="#{@w - mr}" y1="#{ceiling_y}" y2="#{ceiling_y}" stroke="var(--blocking)" stroke-width="1" stroke-dasharray="4 3" opacity="0.7"/>| <>
        text(@w - mr, ceiling_y - 5, "machine ceiling #{round(ceiling)}%", anchor: "end", fill: "var(--blocking)")

    inner =
      y_grid(vmax, yf, ml, @w - mr, fn v -> "#{round(v)}%" end) <>
        stacked_areas(series, layers, xf, yf) <>
        ceiling_mark <>
        x_axis(t0, t1, xf, ml, @w - mr, mt + ph)

    svg(@w, h, inner, "Per-unit CPU over the run")
  end

  @doc "Active units against the concurrency cap; the shaded band above the line is wasted capacity."
  @spec concurrency(map()) :: String.t()
  def concurrency(model) do
    %{series: series, window: %{start_ms: t0, end_ms: t1}, cap: cap, kpis: %{peak_conc: peak}} = model
    h = 220
    {ml, mr, mt, mb} = {30, 14, 16, 26}
    pw = @w - ml - mr
    ph = h - mt - mb
    vmax = max(cap, peak) |> max(1)
    xf = fn t -> ml + (t - t0) / max(t1 - t0, 1) * pw end
    yf = fn v -> mt + ph - v / vmax * ph end

    pts = Enum.map(series, fn s -> {xf.(s.t_ms), yf.(s.conc)} end)
    cap_y = r2(yf.(cap))
    band_top = Enum.map(series, fn s -> {xf.(s.t_ms), yf.(cap)} end)
    band_bot = series |> Enum.map(fn s -> {xf.(s.t_ms), yf.(min(s.conc, cap))} end) |> Enum.reverse()

    inner =
      ~s|<path d="#{poly(band_top ++ band_bot)}" fill="var(--blocking)" fill-opacity="0.07"/>| <>
        ~s|<path d="#{step_area(pts, mt + ph)}" fill="var(--accent)" fill-opacity="0.16"/>| <>
        ~s|<path d="#{step_line(pts)}" fill="none" stroke="var(--accent)" stroke-width="1.8"/>| <>
        ~s|<line x1="#{ml}" x2="#{@w - mr}" y1="#{cap_y}" y2="#{cap_y}" stroke="var(--attention)" stroke-width="1.2" stroke-dasharray="5 3"/>| <>
        text(ml + 2, cap_y - 4, "cap #{cap}", fill: "var(--attention)") <>
        x_axis(t0, t1, xf, ml, @w - mr, mt + ph)

    svg(@w, h, inner, "Concurrency against the cap")
  end

  @doc "Aggregate resident memory over the run against the host ceiling."
  @spec memory(map()) :: String.t()
  def memory(model) do
    %{series: series, window: %{start_ms: t0, end_ms: t1}, host_mem_bytes: host} = model
    h = 220
    {ml, mr, mt, mb} = {46, 14, 16, 26}
    pw = @w - ml - mr
    ph = h - mt - mb
    vmax = max(host, Enum.max([1 | Enum.map(series, & &1.total_mem)]))
    xf = fn t -> ml + (t - t0) / max(t1 - t0, 1) * pw end
    yf = fn v -> mt + ph - v / vmax * ph end
    pts = Enum.map(series, fn s -> {xf.(s.t_ms), yf.(s.total_mem)} end)
    host_y = r2(yf.(host))

    inner =
      ~s|<path d="#{area(pts, mt + ph)}" fill="var(--good)" fill-opacity="0.14"/>| <>
        ~s|<path d="#{line(pts)}" fill="none" stroke="var(--good)" stroke-width="1.8"/>| <>
        ~s|<line x1="#{ml}" x2="#{@w - mr}" y1="#{host_y}" y2="#{host_y}" stroke="var(--blocking)" stroke-width="1" stroke-dasharray="4 3" opacity="0.8"/>| <>
        text(@w - mr, host_y + 12, "host #{fmt_bytes(host)}", anchor: "end", fill: "var(--blocking)") <>
        y_grid(vmax, yf, ml, @w - mr, &fmt_bytes/1) <>
        x_axis(t0, t1, xf, ml, @w - mr, mt + ph)

    svg(@w, h, inner, "Memory over the run")
  end

  @doc "Per-ticket lifecycle: a wait rail into a work bar coloured by status, capped by an end marker."
  @spec gantt(map()) :: String.t()
  def gantt(model) do
    %{tickets: rows, window: %{start_ms: t0, end_ms: t1}} = model
    rowh = 18
    {ml, mr, mt, mb} = {52, 14, 6, 20}
    n = max(length(rows), 1)
    ph = n * rowh
    h = ph + mt + mb
    pw = @w - ml - mr
    xf = fn t -> ml + (clamp(t, t0, t1) - t0) / max(t1 - t0, 1) * pw end

    bars =
      rows
      |> Enum.with_index()
      |> Enum.map_join("", fn {r, i} ->
        y = mt + i * rowh
        color = status_color(r.status)
        wx = r2(xf.(r.start_ms))
        ww = r2(max(xf.(r.work_ms) - xf.(r.start_ms), 0))
        bx = r2(xf.(r.work_ms))
        bw = r2(max(xf.(r.end_ms) - xf.(r.work_ms), 2))

        text(ml - 6, y + rowh / 2 + 3, "##{r.id}", anchor: "end", fill: "var(--muted)") <>
          ~s|<rect x="#{wx}" y="#{r2(y + rowh / 2 - 1.5)}" width="#{ww}" height="3" rx="1.5" fill="var(--faint)" opacity="0.5"/>| <>
          ~s|<rect x="#{bx}" y="#{r2(y + 3)}" width="#{bw}" height="#{rowh - 8}" rx="3" fill="#{color}" fill-opacity="0.85"/>| <>
          ~s|<circle cx="#{r2(xf.(r.end_ms))}" cy="#{r2(y + rowh / 2)}" r="3" fill="#{color}" stroke="var(--surface)" stroke-width="1"/>|
      end)

    svg(@w, h, x_axis(t0, t1, xf, ml, @w - mr, mt + ph) <> bars, "Per-ticket lifecycle")
  end

  @doc "Ranked cost per unit ticket, sortable by CPU-seconds, peak CPU, or peak memory."
  @spec cost(map(), MapSet.t(), atom()) :: String.t()
  def cost(model, selected, sort) do
    valf = cost_metric(sort)
    data = model.actors |> Enum.filter(&MapSet.member?(selected, &1.key)) |> Enum.sort_by(valf, :desc)
    rowh = 22
    {ml, mr, mt} = {52, 60, 4}
    n = max(length(data), 1)
    h = n * rowh + mt + 4
    pw = @w - ml - mr
    maxv = Enum.max([1 | Enum.map(data, valf)])

    bars =
      data
      |> Enum.with_index()
      |> Enum.map_join("", fn {a, i} ->
        y = mt + i * rowh
        bw = r2(max(valf.(a) / maxv * pw, 2))

        text(ml - 6, y + rowh / 2 + 3, a.label, anchor: "end", fill: "var(--muted)") <>
          ~s|<rect x="#{ml}" y="#{y + 3}" width="#{bw}" height="#{rowh - 8}" rx="3" fill="#{scolor(a.color_i)}" fill-opacity="0.85"/>| <>
          text(ml + bw + 6, y + rowh / 2 + 3, cost_label(a, sort), fill: "var(--fg)")
      end)

    svg(@w, h, bars, "Cost per ticket")
  end

  @doc "Cumulative tickets merged against total scope over the run."
  @spec burnup(map()) :: String.t()
  def burnup(model) do
    %{series: series, window: %{start_ms: t0, end_ms: t1}, tickets: rows, kpis: %{total: total}} = model
    merged = rows |> Enum.filter(&(&1.status == :merged)) |> Enum.map(& &1.merged_at) |> Enum.filter(&is_integer/1)
    h = 220
    {ml, mr, mt, mb} = {30, 32, 16, 26}
    pw = @w - ml - mr
    ph = h - mt - mb
    vmax = max(total, 1)
    xf = fn t -> ml + (t - t0) / max(t1 - t0, 1) * pw end
    yf = fn v -> mt + ph - v / vmax * ph end
    pts = Enum.map(series, fn s -> {xf.(s.t_ms), yf.(Enum.count(merged, &(&1 <= s.t_ms)))} end)
    scope_y = r2(yf.(total))

    inner =
      ~s|<line x1="#{ml}" x2="#{@w - mr}" y1="#{scope_y}" y2="#{scope_y}" stroke="var(--muted)" stroke-width="1" stroke-dasharray="5 3" opacity="0.6"/>| <>
        text(@w - mr, scope_y - 5, "scope #{total}", anchor: "end", fill: "var(--muted)") <>
        ~s|<path d="#{step_area(pts, mt + ph)}" fill="var(--good)" fill-opacity="0.15"/>| <>
        ~s|<path d="#{step_line(pts)}" fill="none" stroke="var(--good)" stroke-width="2"/>| <>
        x_axis(t0, t1, xf, ml, @w - mr, mt + ph)

    svg(@w, h, inner, "Burn-up of merged tickets")
  end

  @doc "Ticket count and average observed wall-clock by dispatch-time complexity tier."
  @spec complexity_breakdown(map()) :: String.t()
  def complexity_breakdown(%{complexity_breakdown: tiers}) do
    h = 250
    {ml, mr, mt, mb} = {40, 18, 20, 62}
    pw = @w - ml - mr
    ph = h - mt - mb
    vmax = tiers |> Enum.map(& &1.count) |> Enum.max(fn -> 1 end) |> max(1)
    groupw = pw / max(length(tiers), 1)
    barw = min(groupw * 0.48, 64)

    bars =
      tiers
      |> Enum.with_index()
      |> Enum.map_join("", fn {tier, index} ->
        x = ml + index * groupw + (groupw - barw) / 2
        bar_h = tier.count / vmax * ph
        y = mt + ph - bar_h
        color = "var(--an-s#{tier.tier})"
        count_label = if tier.count > 0, do: to_string(tier.count), else: "—"
        average_label = (tier.average_wall_clock_ms && fmt_elapsed(tier.average_wall_clock_ms)) || "—"
        center = x + barw / 2

        ~s|<rect x="#{r2(x)}" y="#{r2(y)}" width="#{r2(barw)}" height="#{r2(bar_h)}" rx="3" fill="#{color}" fill-opacity="0.85"><title>Complexity #{tier.tier}: #{count_label} tickets, average #{average_label}</title></rect>| <>
          text(center, max(y - 7, mt + 9), count_label, anchor: "middle", fill: "var(--fg)") <>
          text(center, mt + ph + 17, "C#{tier.tier}", anchor: "middle", fill: "var(--fg)") <>
          text(center, mt + ph + 34, average_label, anchor: "middle", fill: "var(--muted)")
      end)

    inner =
      y_grid(vmax, fn value -> mt + ph - value / vmax * ph end, ml, @w - mr, &to_string(round(&1))) <>
        bars

    svg(@w, h, inner, "Complexity breakdown")
  end

  # ---- shared builders ----

  defp stacked_areas(series, layers, xf, yf) do
    zero = Map.new(series, &{&1.idx, 0.0})

    {_cum, out} =
      Enum.reduce(layers, {zero, []}, fn {color, op, vf}, {cum, acc} ->
        next = Map.new(series, fn s -> {s.idx, Map.get(cum, s.idx) + vf.(s)} end)
        top = Enum.map(series, fn s -> {xf.(s.t_ms), yf.(Map.get(next, s.idx))} end)
        bot = series |> Enum.map(fn s -> {xf.(s.t_ms), yf.(Map.get(cum, s.idx))} end) |> Enum.reverse()
        path = ~s|<path d="#{poly(top ++ bot)}" fill="#{color}" fill-opacity="#{op}" stroke="var(--surface)" stroke-width="0.4"/>|
        {next, [path | acc]}
      end)

    out |> Enum.reverse() |> Enum.join()
  end

  defp poly([{x, y} | rest]) do
    "M #{r2(x)},#{r2(y)} " <> Enum.map_join(rest, " ", fn {a, b} -> "L #{r2(a)},#{r2(b)}" end) <> " Z"
  end

  defp poly([]), do: ""

  defp line([{x, y} | rest]) do
    "M #{r2(x)},#{r2(y)} " <> Enum.map_join(rest, " ", fn {a, b} -> "L #{r2(a)},#{r2(b)}" end)
  end

  defp line([]), do: ""

  defp area(pts, base) do
    case pts do
      [] -> ""
      _ -> line(pts) <> " L #{r2(elem(List.last(pts), 0))},#{r2(base)} L #{r2(elem(hd(pts), 0))},#{r2(base)} Z"
    end
  end

  defp step_line([{x, y} | rest]) do
    {d, _} =
      Enum.reduce(rest, {"M #{r2(x)},#{r2(y)}", y}, fn {x2, y2}, {acc, py} ->
        {acc <> " L #{r2(x2)},#{r2(py)} L #{r2(x2)},#{r2(y2)}", y2}
      end)

    d
  end

  defp step_line([]), do: ""

  defp step_area([], _base), do: ""

  defp step_area(pts, base) do
    step_line(pts) <> " L #{r2(elem(List.last(pts), 0))},#{r2(base)} L #{r2(elem(hd(pts), 0))},#{r2(base)} Z"
  end

  defp x_axis(t0, t1, xf, x0, x1, baseline) do
    ticks = for i <- 0..4, do: t0 + (t1 - t0) * i / 4

    base = ~s|<line x1="#{x0}" x2="#{x1}" y1="#{baseline}" y2="#{baseline}" stroke="var(--line)"/>|

    labels =
      Enum.map_join(ticks, "", fn t ->
        text(r2(xf.(t)), baseline + 15, fmt_elapsed(t - t0), anchor: "middle", fill: "var(--muted)")
      end)

    base <> labels
  end

  defp y_grid(vmax, yf, x0, x1, fmt) do
    for i <- 0..3, into: "" do
      v = vmax * i / 3
      y = r2(yf.(v))

      ~s|<line x1="#{x0}" x2="#{x1}" y1="#{y}" y2="#{y}" stroke="var(--hairline)"/>| <>
        text(x0 - 6, y + 3, fmt.(v), anchor: "end", fill: "var(--muted)")
    end
  end

  defp svg(w, h, inner, label) do
    ~s|<svg viewBox="0 0 #{w} #{h}" role="img" aria-label="#{label}" preserveAspectRatio="xMidYMid meet" style="width:100%;height:auto;display:block;overflow:visible">#{inner}</svg>|
  end

  defp text(x, y, body, opts) do
    anchor = Keyword.get(opts, :anchor, "start")
    fill = Keyword.get(opts, :fill, "var(--muted)")
    ~s|<text x="#{x}" y="#{y}" text-anchor="#{anchor}" fill="#{fill}" font-size="9" font-family="var(--an-mono, monospace)">#{body}</text>|
  end

  # ---- formatting / palette ----

  defp scolor(i), do: "var(--an-s#{rem(i - 1, 8) + 1})"

  defp status_color(:merged), do: "var(--good)"
  defp status_color(:rework), do: "var(--blocking)"
  defp status_color(:paused), do: "var(--faint)"
  defp status_color(_active), do: "var(--accent)"

  defp cost_metric(:peakcpu), do: & &1.peak_cpu
  defp cost_metric(:mem), do: & &1.peak_mem_bytes
  defp cost_metric(_cpu), do: & &1.cpu_seconds

  defp cost_label(a, :peakcpu), do: "#{round(a.peak_cpu)}%"
  defp cost_label(a, :mem), do: fmt_bytes(a.peak_mem_bytes)
  defp cost_label(a, _cpu), do: "#{a.cpu_seconds}s"

  defp fmt_elapsed(ms) when ms <= 0, do: "0m"

  defp fmt_elapsed(ms) do
    total_min = div(round(ms / 1000), 60)
    h = div(total_min, 60)
    m = rem(total_min, 60)

    cond do
      h > 0 and m > 0 -> "#{h}h #{m}m"
      h > 0 -> "#{h}h"
      true -> "#{total_min}m"
    end
  end

  defp fmt_bytes(b) when is_number(b) do
    cond do
      b >= 1_073_741_824 -> "#{Float.round(b / 1_073_741_824, 1)} GB"
      b >= 1_048_576 -> "#{round(b / 1_048_576)} MB"
      b >= 1024 -> "#{round(b / 1024)} KB"
      true -> "#{round(b)} B"
    end
  end

  defp fmt_bytes(_b), do: "0 B"

  defp r2(v) when is_number(v), do: Float.round(v * 1.0, 2)
  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)
end
