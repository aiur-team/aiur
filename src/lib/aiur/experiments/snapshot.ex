defmodule Aiur.Experiments.Snapshot do
  @moduledoc false
  alias Aiur.Experiments.{Catalog, Evidence, Journal, Paths, Persistence, Reader, Schema, SnapshotPersistence, WindowData}

  @spec freeze(String.t(), String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def freeze(id, name \\ nil, opts \\ []) do
    with :ok <- Persistence.recover_one(id), {:ok, prepared} <- prepare(id, name, opts), do: commit_prepared(prepared)
  end

  @spec prepare(String.t(), String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(id, name, opts) do
    with :ok <- Persistence.writable(id),
         {:ok, spec, false} <- Reader.spec(id),
         name = name || default_window(spec),
         {:ok, old} <- latest(id, name),
         :ok <- reason(old, opts),
         {:ok, data} <- WindowData.evaluate(spec, name, context(opts)),
         {:ok, snapshot} <- prepare_spec(spec, name, old, data, opts) do
      {:ok, %{id: id, spec: spec, name: name, old: old, snapshot: snapshot, opts: opts}}
    end
  end

  @spec prepare_spec(map(), String.t(), map() | nil, map(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare_spec(spec, name, old, data, opts) do
    data = retain_old(old, data)
    with :ok <- reason(old, opts), :ok <- size_guard(data.metrics, opts), do: {:ok, build(spec, name, old, data, opts)}
  end

  @spec commit_prepared(map()) :: {:ok, map()} | {:error, term()}
  def commit_prepared(prepared) do
    with :ok <- unchanged_spec(prepared.id, prepared.spec),
         {:ok, old} <- latest(prepared.id, prepared.name),
         true <- old == prepared.old,
         :ok <- SnapshotPersistence.commit(prepared.id, prepared.name, prepared.snapshot, prepared.opts) do
      {:ok, prepared.snapshot}
    else
      false -> {:error, :stale_preparation}
      error -> error
    end
  end

  @spec unchanged_spec(String.t(), map()) :: :ok | {:error, term()}
  def unchanged_spec(id, expected) do
    with {:ok, current, false} <- Reader.spec(id) do
      if Map.delete(current, "registered_at") == Map.delete(expected, "registered_at"), do: :ok, else: {:error, :stale_preparation}
    end
  end

  @spec default_window(map()) :: String.t()
  def default_window(spec), do: if(spec["design"]["kind"] == "before_after", do: "before", else: "observation")

  defp context(opts) do
    ctx = Keyword.get(opts, :context, %{})
    if opts[:now], do: Map.put(ctx, :clock, opts[:now]), else: ctx
  end

  defp reason(nil, _opts), do: :ok
  defp reason(old, opts), do: if(is_binary(opts[:reason]) and String.trim(opts[:reason]) != "", do: :ok, else: {:error, {:reason_required, old["revision"]}})

  defp retain_old(nil, data), do: data

  defp retain_old(old, data) do
    metrics =
      Map.new(data.metrics, fn {ref, result} ->
        saved = get_in(old, ["metrics", ref, "observations"]) || []
        completed = Enum.reject(saved, & &1["censored"])
        pending = Enum.filter(saved, & &1["censored"])
        rows = (completed ++ result["observations"] ++ pending) |> Enum.uniq_by(& &1["unit_id"]) |> Enum.sort_by(& &1["unit_id"])
        {ref, Map.put(result, "observations", rows)}
      end)

    %{data | metrics: metrics}
  end

  defp size_guard(metrics, opts) do
    counts = Map.new(metrics, fn {ref, metric} -> {ref, length(metric["observations"])} end)
    limit = Keyword.get(opts, :max_observations, settings_limit())
    if Enum.sum(Map.values(counts)) > limit, do: {:error, {:too_many_observations, counts}}, else: :ok
  end

  defp settings_limit do
    case Aiur.Config.settings() do
      {:ok, %{experiments: config}} -> config.max_snapshot_observations
      _ -> 50_000
    end
  end

  defp build(spec, name, old, data, opts) do
    snapshot = %{
      "schema_version" => Schema.current(),
      "experiment_id" => spec["id"],
      "window_name" => name,
      "window" => data.window,
      "revision" => if(old, do: old["revision"] + 1, else: 1),
      "computed_at" => timestamp(opts),
      "aiur_version" => to_string(Application.spec(:aiur, :vsn)),
      "packs" => packs(spec, context(opts)),
      "metrics" => Map.new(data.metrics, fn {ref, result} -> {ref, Map.put(result, "summary", summary(result["observations"]))} end)
    }

    snapshot = Map.put(snapshot, "observation_count", Enum.sum(for {_ref, result} <- data.metrics, do: length(result["observations"])))
    Map.put(snapshot, "sha256", Evidence.hash(snapshot))
  end

  defp timestamp(opts), do: (opts[:now] || DateTime.utc_now()) |> DateTime.to_iso8601()

  @spec packs(map(), map()) :: [map()]
  def packs(spec, ctx) do
    catalog = Map.get_lazy(ctx, :catalog, fn -> Catalog.load(ctx) end)
    spec["metrics"] |> Enum.map(&(String.split(&1["ref"], "/") |> hd())) |> Enum.uniq() |> Enum.sort() |> Enum.map(&pack(&1, catalog))
  end

  defp pack(id, catalog) do
    case catalog.packs[id] do
      nil -> %{"id" => id, "version" => nil, "definition_sha256" => nil}
      module when is_atom(module) -> %{"id" => id, "version" => module.version(), "definition_sha256" => Evidence.hash(module.metrics())}
      pack -> %{"id" => id, "version" => pack["version"], "definition_sha256" => Evidence.hash(Map.delete(pack, "file"))}
    end
  end

  @spec summary([map()]) :: map()
  def summary(rows) do
    values = Enum.map(rows, & &1["value"]) |> Enum.sort()
    %{"n" => length(values), "median" => quantile(values, 0.5), "p25" => quantile(values, 0.25), "p75" => quantile(values, 0.75), "min" => List.first(values), "max" => List.last(values)}
  end

  defp quantile([], _q), do: nil

  defp quantile(values, q) do
    index = (length(values) - 1) * q
    low = Enum.at(values, floor(index))
    low + (Enum.at(values, ceil(index)) - low) * (index - floor(index))
  end

  @spec latest(String.t(), String.t()) :: {:ok, map() | nil} | {:error, term()}
  def latest(id, name) do
    with {:ok, snapshots} <- all(id) do
      {:ok, snapshots |> Enum.filter(&(&1["window_name"] == name)) |> Enum.max_by(& &1["revision"], fn -> nil end)}
    end
  end

  @spec all(String.t()) :: {:ok, [map()]} | {:error, term()}
  def all(id) do
    with {:ok, journal} <- Journal.read(Paths.file(id, "journal.ndjson")),
         :ok <- existing_revisions(id, journal) do
      Paths.file(id, "snapshots/*.r*.json") |> Path.wildcard() |> Enum.sort() |> Enum.reduce_while({:ok, []}, &read_next(&1, &2, journal))
    end
  end

  defp existing_revisions(id, journal) do
    missing? =
      journal
      |> Enum.filter(&(&1["kind"] == "frozen"))
      |> Enum.any?(fn entry ->
        not File.regular?(Paths.file(id, "snapshots/#{entry["window"]}.r#{entry["revision"]}.json"))
      end)

    if missing?, do: {:error, :tampered}, else: :ok
  end

  defp read_next(path, {:ok, snapshots}, journal) do
    with {:ok, snapshot} <- read(path), :ok <- journaled(snapshot, journal) do
      {:cont, {:ok, snapshots ++ [snapshot]}}
    else
      error -> {:halt, error}
    end
  end

  @spec read(Path.t()) :: {:ok, map()} | {:error, term()}
  def read(path) do
    with {:ok, snapshot} <- Reader.json(path),
         true <- Evidence.hash(Map.delete(snapshot, "sha256")) == snapshot["sha256"],
         {:ok, snapshot} <- Schema.migrate(snapshot) do
      {:ok, snapshot}
    else
      {:error, {:newer_version, _}} = error -> error
      _ -> {:error, :tampered}
    end
  end

  defp journaled(snapshot, entries) do
    found = Enum.any?(entries, &(&1["kind"] == "frozen" and &1["window"] == snapshot["window_name"] and &1["revision"] == snapshot["revision"] and &1["sha256"] == snapshot["sha256"]))
    if found, do: :ok, else: {:error, :tampered}
  end
end
