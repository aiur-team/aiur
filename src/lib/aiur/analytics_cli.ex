defmodule Aiur.AnalyticsCLI do
  @moduledoc false

  alias Aiur.JSONSafe
  alias AiurWeb.OperatorControlCenter.Analytics.{Charts, Presenter, ScopeResolver}

  @ranges ~w(run full)a

  @spec run(keyword()) :: 0 | 1
  def run(opts \\ []) do
    case build(opts) do
      {:ok, envelope} ->
        if Keyword.get(opts, :json, false), do: IO.puts(Jason.encode!(envelope)), else: print_human(envelope)
        0

      {:error, reason} ->
        IO.puts(:stderr, "aiur: analytics #{reason}")
        1
    end
  end

  @doc false
  @spec build(keyword()) :: {:ok, map()} | {:error, String.t()}
  def build(opts \\ [])

  def build(opts) when is_list(opts) do
    case request(opts) do
      {:ok, request} -> build_request(request, opts)
      {:error, _reason} = error -> error
    end
  end

  def build(_opts), do: {:error, "expects command options"}

  defp request(opts) do
    with {:ok, range} <- range(Keyword.get(opts, :range, :run)),
         {:ok, since} <- timestamp(Keyword.get(opts, :since)),
         {:ok, until} <- timestamp(Keyword.get(opts, :until)),
         :ok <- valid_order(since, until) do
      {:ok,
       %{range: range}
       |> maybe_put(:since, since)
       |> maybe_put(:until, until)
       |> maybe_put(:build_order, Keyword.get(opts, :build_order))}
    end
  end

  defp range(range) when range in @ranges, do: {:ok, range}
  defp range("run"), do: {:ok, :run}
  defp range("full"), do: {:ok, :full}
  defp range(range) when is_binary(range), do: {:error, "accepts --range run or full"}
  defp range(_range), do: {:error, "accepts --range run or full"}

  defp timestamp(nil), do: {:ok, nil}
  defp timestamp(%DateTime{} = value), do: {:ok, value}

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> {:ok, parsed}
      _invalid -> {:error, "expects --since and --until as ISO-8601 timestamps"}
    end
  end

  defp timestamp(_value), do: {:error, "expects --since and --until as ISO-8601 timestamps"}
  defp valid_order(nil, _until), do: :ok
  defp valid_order(_since, nil), do: :ok
  defp valid_order(since, until), do: if(DateTime.compare(since, until) == :lt, do: :ok, else: {:error, "requires --since to be before --until"})

  # `fetch: true` because this is a one-shot command with a real need: an
  # operator asked for this Build Order's analytics now, and a cold graph the
  # CLI declines to fetch is an empty report rather than a cheap one. The
  # Analytics *page* takes the default and never fetches.
  defp resolve_scope(request, opts) do
    resolver = Keyword.get(opts, :scope_resolver, &ScopeResolver.resolve(&1, fetch: true))
    resolver.(request[:build_order])
  end

  defp build_request(request, opts) do
    case resolve_scope(request, opts) do
      :unavailable -> unavailable_envelope(request, :build_order_unavailable, :unavailable, opts)
      scope -> build_scope(scope, request, opts)
    end
  end

  defp build_scope(scope, request, opts) do
    with {:ok, model} <- load_model(scope, request, opts),
         {:ok, view, rendered_range} <- render_window(model, request) do
      captured_at = Keyword.get(opts, :now, DateTime.utc_now())

      {:ok,
       %{
         schema_version: 1,
         page: "analytics",
         snapshot: %{captured_at: captured_at},
         request: request,
         sources: sources(scope, view, model, captured_at),
         data: %{model: view, scope: scope_view(scope), range: Map.put(rendered_range, :applies_to, :time_charts)},
         auxiliary: %{provider_spend: %{source: unavailable_source(:financial_capability_required), data: nil}}
       }
       |> JSONSafe.normalize()}
    else
      {:unavailable, {reason, unavailable_scope}} -> unavailable_envelope(request, reason, unavailable_scope, opts)
    end
  end

  defp load_model(:unavailable, _request, _opts), do: :unavailable

  defp load_model(scope, request, opts) do
    load = Keyword.get(opts, :presenter_load, &Presenter.load/1)
    session = if request.range == :full, do: :cross, else: :current

    telemetry_file = Keyword.get(opts, :telemetry_file, Application.get_env(:aiur, :analytics_telemetry_file))

    case load.([range: request.range, session: session, telemetry_file: telemetry_file] ++ ScopeResolver.telemetry_opts(scope)) do
      {:ok, model} -> {:ok, model}
      {:unavailable, reason} -> {:unavailable, {reason, scope}}
    end
  end

  defp render_window(model, request) do
    start_ms = timestamp_ms(request[:since], Map.get(model.window, :start_ms))
    end_ms = timestamp_ms(request[:until], Map.get(model.window, :end_ms))

    if end_ms < model.window.start_ms or start_ms > model.window.end_ms do
      {:ok, nil, %{start: start_ms, end: end_ms, mode: request.range, state: :empty}}
    else
      start_ms = max(start_ms, model.window.start_ms)
      end_ms = min(end_ms, model.window.end_ms)
      view = Charts.with_exact_time_domain(model, {start_ms, end_ms}, boundary_samples: false)
      {:ok, view, %{start: start_ms, end: end_ms, mode: request.range, state: :available}}
    end
  end

  defp timestamp_ms(%DateTime{} = value, _fallback), do: DateTime.to_unix(value, :millisecond)
  defp timestamp_ms(_value, fallback), do: fallback

  defp sources(scope, nil, _source_model, _captured_at),
    do: scope_source(scope, %{state: :empty, observed_at: nil, age_ms: nil, freshness: :unknown, partial: false, reasons: [:empty_window]})

  defp sources(scope, _view, source_model, captured_at) do
    observed_at = source_observed_at(source_model)
    age_ms = if observed_at, do: max(DateTime.diff(captured_at, observed_at, :millisecond), 0)

    freshness =
      cond do
        is_nil(age_ms) -> :unknown
        age_ms <= 30_000 -> :current
        true -> :stale
      end

    scope_source(scope, %{state: :available, observed_at: observed_at, age_ms: age_ms, freshness: freshness, partial: false, reasons: []})
  end

  defp scope_source(:session, telemetry), do: %{telemetry: telemetry}

  defp scope_source(:unavailable, telemetry),
    do: %{telemetry: telemetry, planning_graph: unavailable_source(:build_order_unavailable)}

  defp scope_source(_scope, telemetry),
    do: %{telemetry: telemetry, planning_graph: %{state: :available, observed_at: nil, age_ms: nil, freshness: :unknown, partial: false, reasons: []}}

  defp unavailable_envelope(request, reason, scope, opts) do
    captured_at = Keyword.get(opts, :now, DateTime.utc_now())

    {:ok,
     %{
       schema_version: 1,
       page: "analytics",
       snapshot: %{captured_at: captured_at},
       request: request,
       sources: scope_source(scope, unavailable_source(reason)),
       data: %{model: nil, scope: scope_view(scope), range: unavailable_range(request)},
       auxiliary: %{provider_spend: %{source: unavailable_source(:financial_capability_required), data: nil}}
     }
     |> JSONSafe.normalize()}
  end

  defp unavailable_source(reason), do: %{state: :unavailable, observed_at: nil, age_ms: nil, freshness: :unknown, partial: true, reasons: [reason]}

  defp source_observed_at(%{source_observed_at: value}) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, observed_at, _offset} -> observed_at
      _invalid -> nil
    end
  end

  defp source_observed_at(_model), do: nil
  defp unavailable_range(request), do: %{start: request[:since], end: request[:until], mode: request.range, state: :unavailable}
  defp scope_view(:session), do: %{kind: :session}
  defp scope_view(:unavailable), do: nil
  defp scope_view(%{kind: :build_order, root_number: root_number, tickets: tickets, total: total}), do: %{kind: :build_order, root_number: root_number, tickets: MapSet.to_list(tickets), total: total}

  defp print_human(envelope) do
    IO.puts(["Analytics captured ", get_in(envelope, ["snapshot", "captured_at"])])
    Enum.each(envelope["sources"], fn {name, source} -> print_source(name, source) end)
    provider = get_in(envelope, ["auxiliary", "provider_spend", "source"])
    print_source("provider_spend", provider)

    print_window(get_in(envelope, ["data", "range"]))

    case get_in(envelope, ["data", "model"]) do
      nil ->
        IO.puts("No run telemetry to analyze for this window.")

      model ->
        IO.puts(["Scope: ", scope_label(get_in(envelope, ["data", "scope"]))])
        IO.puts("Page metrics for selected scope (run-scoped, as on /analytics):")
        metrics = get_in(envelope, ["data", "model", "kpis"])
        IO.puts(["Peak concurrency: ", to_string(metrics["peak_conc"]), "; mean utilization: ", to_string(metrics["mean_util_pct"]), "%"])
        IO.puts(["Memory headroom: ", to_string(metrics["mem_headroom_pct"]), "%"])
        IO.puts(["PRs merged: ", to_string(metrics["merged"])])
        IO.puts(["Tickets done: ", to_string(metrics["done"]), "/", to_string(metrics["total"])])
        IO.puts(["Wasted capacity: ", to_string(metrics["wasted_slot_hours"]), "h"])
        IO.puts("Complexity tiers:")

        Enum.each(model["complexity_breakdown"], fn tier ->
          average = tier["average_wall_clock_ms"] |> elapsed() || "unknown"
          IO.puts(["  tier ", to_string(tier["tier"]), ": ", to_string(tier["count"]), " tickets; average wall-clock ", average])
        end)
    end
  end

  defp print_source(name, source) do
    observed_at = source["observed_at"] || "unknown"
    age = if is_integer(source["age_ms"]), do: "#{source["age_ms"]}ms", else: "unknown"

    IO.puts([name, ": ", source["state"], "; freshness ", source["freshness"], "; observed ", observed_at, "; age ", age])
  end

  defp iso(ms) when is_integer(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
  defp iso(value) when is_binary(value), do: value
  defp iso(_ms), do: "unknown"

  defp elapsed(nil), do: nil
  defp elapsed(ms) when ms <= 0, do: "0m"

  defp elapsed(ms) when is_number(ms) do
    total_min = ms |> Kernel./(1_000) |> round() |> div(60)
    hours = div(total_min, 60)
    minutes = rem(total_min, 60)

    cond do
      hours > 0 and minutes > 0 -> "#{hours}h #{minutes}m"
      hours > 0 -> "#{hours}h"
      true -> "#{total_min}m"
    end
  end

  defp elapsed(_value), do: nil

  defp print_window(%{"state" => "unavailable", "mode" => mode, "start" => start, "end" => finish}) when is_binary(start) or is_binary(finish),
    do: IO.puts(["Window: unavailable; requested ", iso(start), " to ", iso(finish), " (", mode, ")"])

  defp print_window(%{"state" => "unavailable", "mode" => mode}), do: IO.puts(["Window: unavailable (", mode, ")"])

  defp print_window(%{"state" => "empty", "mode" => mode, "start" => start, "end" => finish}) do
    IO.puts(["Window: no telemetry in requested interval ", iso(start), " to ", iso(finish), " (", mode, ")"])
  end

  defp print_window(range), do: IO.puts(["Chart window: ", iso(range["start"]), " to ", iso(range["end"]), " (", range["mode"], ")"])
  defp scope_label(%{"kind" => "build_order", "root_number" => root}), do: "Build Order ##{root}"
  defp scope_label(_scope), do: "this session"
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
