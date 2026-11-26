defmodule Aiur.Experiments.BaselineImport do
  @moduledoc false

  alias Aiur.Experiments.{Evidence, Paths, Persistence, Reader, Schema, Snapshot, SnapshotPersistence}

  @spec run(String.t(), binary(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(id, source_bytes, expected_sha256, opts \\ []) do
    metric_ref = Keyword.get(opts, :metric_ref)
    summary_path = Keyword.get(opts, :summary_path, ["primary", "blocker_merge_to_dependent_start", "all"])
    window_name = Keyword.get(opts, :window, "before")

    with true <- Paths.valid_id?(id),
         true <- is_binary(source_bytes),
         true <- is_binary(expected_sha256) and Regex.match?(~r/^[0-9a-f]{64}$/, expected_sha256),
         actual_sha <- :crypto.hash(:sha256, source_bytes) |> Base.encode16(case: :lower),
         true <- actual_sha == expected_sha256,
         {:ok, source} <- Jason.decode(source_bytes),
         :ok <- Persistence.writable(id),
         :ok <- Persistence.recover_one(id),
         {:ok, spec, false} <- Reader.spec(id),
         true <- is_binary(metric_ref) and Enum.any?(spec["metrics"], &(&1["ref"] == metric_ref)),
         {:ok, summary} when is_map(summary) <- fetch_path(source, summary_path),
         :ok <- valid_summary(summary),
         {:ok, old} <- Snapshot.latest(id, window_name),
         :ok <- reason(old, opts),
         snapshot <-
           snapshot(id, %{
             spec: spec,
             source: source,
             metric_ref: metric_ref,
             summary: summary,
             bytes: source_bytes,
             source_sha: actual_sha,
             old: old,
             window_name: window_name,
             summary_path: summary_path,
             opts: opts
           }),
         :ok <- SnapshotPersistence.commit(id, window_name, snapshot, Keyword.merge(opts, imported_source_sha256: actual_sha, source_path: Keyword.get(opts, :source_path))) do
      {:ok, snapshot}
    else
      false -> {:error, :invalid_baseline}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_baseline}
    end
  end

  defp fetch_path(value, []), do: {:ok, value}
  defp fetch_path(value, [key | rest]) when is_map(value), do: fetch_path(value[key], rest)
  defp fetch_path(_value, _path), do: {:error, :summary_not_found}

  defp valid_summary(%{"n" => n, "median_h" => median}) when is_integer(n) and n >= 0 and is_number(median), do: :ok
  defp valid_summary(_summary), do: {:error, :invalid_summary}

  defp reason(nil, _opts), do: :ok
  defp reason(old, opts), do: if(is_binary(opts[:reason]) and String.trim(opts[:reason]) != "", do: :ok, else: {:error, {:reason_required, old["revision"]}})

  defp snapshot(id, %{
         spec: spec,
         source: source,
         metric_ref: metric_ref,
         summary: summary,
         bytes: bytes,
         source_sha: source_sha,
         old: old,
         window_name: window_name,
         summary_path: summary_path,
         opts: opts
       }) do
    window = %{"start" => source["window_start"], "end" => source["cut"]}
    window = if is_binary(window["start"]) and is_binary(window["end"]), do: window, else: spec["windows"][window_name] || spec["windows"]["observation"] || %{}

    metrics =
      Map.new(spec["metrics"], fn metric ->
        ref = metric["ref"]
        imported? = ref == metric_ref
        value = if imported?, do: summary, else: %{"n" => 0, "median_h" => nil}
        standard = %{"n" => value["n"], "median" => value["median_h"], "p25" => value["p25_h"], "p75" => value["p75_h"], "min" => value["min_h"], "max" => value["max_h"]}
        {ref, %{"coverage" => %{"state" => if(imported?, do: "summary_only", else: "unavailable"), "reason" => "raw_observations_unavailable"}, "observations" => [], "summary" => standard}}
      end)

    data = %{
      "schema_version" => Schema.current(),
      "experiment_id" => id,
      "window_name" => window_name,
      "window" => window,
      "revision" => if(old, do: old["revision"] + 1, else: 1),
      "computed_at" => DateTime.to_iso8601(opts[:now] || DateTime.utc_now()),
      "aiur_version" => to_string(Application.spec(:aiur, :vsn)),
      "packs" => [],
      "metrics" => metrics,
      "observation_count" => 0,
      "baseline_import" => %{
        "source_sha256" => source_sha,
        "source_bytes_base64" => Base.encode64(bytes),
        "summary_path" => summary_path,
        "metric_ref" => metric_ref,
        "summary" => summary,
        "provenance" => Keyword.get(opts, :source_path)
      }
    }

    Map.put(data, "sha256", Evidence.hash(data))
  end
end
