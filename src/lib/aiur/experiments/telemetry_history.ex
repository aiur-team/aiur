defmodule Aiur.Experiments.TelemetryHistory do
  @moduledoc "Per-summary cached lifecycle and fleet projections; incomplete boots preserve usable history."
  alias Aiur.Experiments.TelemetryReader
  alias Aiur.RunTelemetry.{RetainedCache, Summaries}

  @retained_bytes 4 * 1024 * 1024

  @doc "Each summary has independent read limits and a path/size/mtime cache identity. Live telemetry is never cached."
  @spec read(String.t() | nil, map()) :: {:ok, map()}
  def read(current, ctx \\ %{}) do
    path = Map.get(ctx, :summary_path, &Summaries.run_summary_path/1)

    opts =
      ctx
      |> Map.get(:telemetry_reader_options, [])
      |> Keyword.put_new(:max_records, 100_000)
      |> Keyword.put_new(:projection, :fleet)
      |> Keyword.put_new(:keep_kinds, ~w(lifecycle run_context restart resource))

    empty = %{records: [], samples: [], state: :complete, retained_bytes: 0, partial_records: [], partial_samples: [], partial_bytes: 0, warnings: []}

    result =
      Map.get(ctx, :summary_boot_ids, &Summaries.summary_boot_ids/0).()
      |> Enum.reject(&(&1 == current))
      |> Enum.reduce(empty, fn boot, acc -> merge(acc, projection(path.(boot), opts)) end)

    {:ok, %{result | records: result.records ++ result.partial_records, samples: result.samples ++ result.partial_samples}}
  end

  defp projection(path, opts) do
    identity =
      case File.stat(path, time: :posix) do
        {:ok, stat} -> {path, stat.size, stat.mtime}
        {:error, reason} -> {path, reason}
      end

    # History has no boot-range index: cold reads include every earlier/unknown boot.
    window = %{start: ~U[0000-01-01 00:00:00Z], end: ~U[9999-12-31 23:59:59Z]}

    RetainedCache.fetch(
      __MODULE__,
      {identity, opts},
      fn ->
        {:ok, projection} = TelemetryReader.read(window, [%{path: path, format: :summary}], opts)
        projection
      end,
      max_value_bytes: 8 * 1024 * 1024,
      max_entries: 64
    )
  end

  defp merge(acc, %{state: :truncated} = projection) do
    bytes = :erlang.external_size({projection.records, projection.samples})
    acc = %{acc | state: :partial}

    if acc.retained_bytes + acc.partial_bytes + bytes <= @retained_bytes do
      %{acc | partial_records: projection.records ++ acc.partial_records, partial_samples: projection.samples ++ acc.partial_samples, partial_bytes: acc.partial_bytes + bytes}
    else
      acc
    end
  end

  defp merge(acc, projection) do
    bytes = :erlang.external_size({projection.records, projection.samples})
    partial = acc.state != :complete or projection.state != :complete
    # Complete boot projections take precedence over any previously retained truncated prefix.
    acc = if acc.retained_bytes + acc.partial_bytes + bytes > @retained_bytes, do: %{acc | partial_records: [], partial_samples: [], partial_bytes: 0}, else: acc

    if acc.retained_bytes + acc.partial_bytes + bytes <= @retained_bytes do
      %{
        acc
        | records: projection.records ++ acc.records,
          samples: projection.samples ++ acc.samples,
          state: if(partial, do: :partial, else: :complete),
          retained_bytes: acc.retained_bytes + bytes,
          warnings: Enum.take(projection.warnings ++ acc.warnings, 32)
      }
    else
      %{acc | state: :partial}
    end
  end
end
