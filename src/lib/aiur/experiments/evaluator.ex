defmodule Aiur.Experiments.Evaluator do
  @moduledoc "Evaluates catalog metrics against a window without treating missing data as zero."

  alias Aiur.Experiments.Catalog
  alias Aiur.Experiments.Sources.{Common, EventCount, EventInterval, Ndjson, Script}

  @sources %{"event_interval" => EventInterval, "event_count" => EventCount, "ndjson" => Ndjson, "script" => Script}

  @spec observations([String.t()], map(), map()) :: map()
  def observations(refs, window, ctx \\ %{}) do
    catalog = Map.get_lazy(ctx, :catalog, fn -> Catalog.load(ctx) end)

    case normalize_window(window, ctx) do
      {:ok, window} ->
        ctx = if event_refs?(refs, catalog), do: Common.prepare_context(Map.get(ctx, :interval_window, window), ctx), else: ctx

        refs
        |> Enum.group_by(fn ref -> ref |> String.split("/", parts: 2) |> hd() end)
        |> Enum.flat_map(fn {pack, refs} -> evaluate_pack(catalog, pack, refs, window, ctx) end)
        |> Map.new()

      {:error, reason} ->
        Map.new(refs, &{&1, Common.unavailable(reason)})
    end
  end

  defp event_refs?(refs, catalog) do
    Enum.any?(refs, fn ref ->
      case catalog.metrics[ref] do
        %{pack: pack, source: %{"kind" => kind}} when kind in ["event_interval", "event_count"] -> not is_atom(catalog.packs[pack]) or is_nil(catalog.packs[pack])
        _metric -> false
      end
    end)
  end

  defp normalize_window(window, ctx) when is_map(window) do
    start = Common.timestamp(Map.get(window, :start, window["start"]))
    finish = Common.timestamp(Map.get(window, :end, window["end"]) || now(ctx))
    if start && finish && DateTime.compare(start, finish) == :lt, do: {:ok, %{start: start, end: finish}}, else: {:error, :invalid_window}
  end

  defp normalize_window(_window, _ctx), do: {:error, :invalid_window}

  defp now(ctx) do
    case Map.get(ctx, :clock, &DateTime.utc_now/0) do
      clock when is_function(clock, 0) -> clock.()
      at -> at
    end
  end

  defp evaluate_pack(catalog, pack, refs, window, ctx) do
    case catalog.packs[pack] do
      module when is_atom(module) and not is_nil(module) -> evaluate_builtin(module, catalog, refs, window, ctx)
      _consumer -> Enum.map(refs, &{&1, evaluate_consumer(catalog.metrics[&1], &1, window, ctx)})
    end
  end

  defp evaluate_builtin(module, catalog, refs, window, ctx) do
    ids = for ref <- refs, metric = catalog.metrics[ref], metric != nil, do: metric.id
    rows = module.observations(ids, window, ctx)

    Enum.map(refs, fn ref ->
      result =
        case catalog.metrics[ref] do
          nil -> Common.unavailable(:metric_missing)
          metric -> builtin_result(rows[metric.id])
        end

      {ref, result}
    end)
  rescue
    error -> Enum.map(refs, &{&1, Common.unavailable({:pack_failed, Exception.message(error)})})
  catch
    :exit, reason -> Enum.map(refs, &{&1, Common.unavailable({:pack_failed, reason})})
  end

  defp builtin_result({coverage, observations}), do: Common.result(coverage, observations)
  defp builtin_result(%{coverage: _coverage, observations: _observations} = result), do: result
  defp builtin_result(_missing), do: Common.unavailable(:metric_missing)

  defp evaluate_consumer(nil, _ref, _window, _ctx), do: Common.unavailable(:metric_missing)

  defp evaluate_consumer(metric, ref, window, ctx) do
    case @sources[metric.source["kind"]] do
      nil -> Common.unavailable(:source_invalid)
      module -> module.observations(metric, ref, window, ctx)
    end
  end
end
