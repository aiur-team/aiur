defmodule Aiur.RunTelemetry.Summaries do
  @moduledoc """
  Materialized run summaries and build-order rollups in the per-repo state node.

  Layout (beside `RepoBase.builds_path/1`):

      ~/.aiur/repo/<owner>/<name>/
      ├── analytics/
      │   ├── runs/<boot-id>/run-summary.json     # one reduced dataset per boot
      │   └── flakes.ndjson                       # reserved (flake-report; blocked)
      └── builds/<slug>/build-summary.json        # cross-boot build rollup

  Materialization is a cache, never a source of truth. The canonical reducer is
  the `analytics/` Python package: this module invokes `analytics/reduce` on
  telemetry segment boundaries and on daemon shutdown, then the dashboard
  Presenter reads prior boots from the materialized summaries instead of
  re-parsing the full raw stream. Every summary carries provenance
  (`source_files`/`source_bytes`/`generated_at`) so it is detectable as stale
  and regenerable.

  All operations fail open: when the state node, the reducer, or the telemetry
  stream is unavailable, materialization is a no-op and reads return
  `{:error, :missing}` so telemetry can never become an orchestration
  dependency.
  """

  require Logger

  alias Aiur.GitHub.Config
  alias Aiur.RepoBase
  alias Aiur.RunTelemetry

  @reduce_tool "reduce"
  @materialize_timeout_ms 30_000

  ## ---- paths ----

  @doc "The repository slug this host's daemon tracks (owner/name or local fallback)."
  @spec repo_url() :: String.t()
  def repo_url do
    case Application.get_env(:aiur, :analytics_repo) do
      repo when is_binary(repo) and repo != "" ->
        repo

      _other ->
        case Config.repo() do
          repo when is_binary(repo) and repo != "" -> repo
          _other -> "local/repo"
        end
    end
  end

  @doc "The per-repo state node root (`RepoBase.repo_path/1`)."
  @spec state_node() :: Path.t()
  def state_node do
    RepoBase.repo_path(repo_url())
  rescue
    _error -> Path.expand("~/.aiur/repo/local/repo")
  catch
    _kind, _reason -> Path.expand("~/.aiur/repo/local/repo")
  end

  @doc "`<state-node>/analytics` — the analytics output root."
  @spec analytics_dir() :: Path.t()
  def analytics_dir, do: Path.join(state_node(), "analytics")

  @doc "`<state-node>/analytics/runs` — one run-summary per boot."
  @spec runs_dir() :: Path.t()
  def runs_dir, do: Path.join(analytics_dir(), "runs")

  @doc "`<state-node>/builds` — `RepoBase.builds_path/1`, the real writer target for build rollups."
  @spec builds_dir() :: Path.t()
  def builds_dir, do: RepoBase.builds_path(repo_url())

  @doc "Path of one boot's run-summary."
  @spec run_summary_path(String.t()) :: Path.t()
  def run_summary_path(boot_id) when is_binary(boot_id),
    do: Path.join([runs_dir(), boot_id, "run-summary.json"])

  @doc "Path of one build order's cross-boot rollup."
  @spec build_summary_path(String.t()) :: Path.t()
  def build_summary_path(slug) when is_binary(slug),
    do: Path.join([builds_dir(), slug, "build-summary.json"])

  @doc "Materialized run-summary boot ids, sorted."
  @spec summary_boot_ids() :: [String.t()]
  def summary_boot_ids do
    case File.ls(runs_dir()) do
      {:ok, entries} ->
        entries
        |> Enum.filter(fn entry -> File.dir?(Path.join(runs_dir(), entry)) end)
        |> Enum.sort()

      _error ->
        []
    end
  end

  ## ---- materialization ----

  @doc """
  Asynchronously materialize run-summaries and build rollups (fire-and-forget).

  Called by the telemetry Writer on segment boundaries. Returns `:ok`
  immediately; a failure in the background task is logged and never affects the
  caller.
  """
  @spec materialize_async() :: :ok
  def materialize_async do
    case reduce_command() do
      {:ok, {script, args}} -> Task.start(fn -> run_reduce_background(script, args) end)
      :unavailable -> :ok
    end

    :ok
  end

  defp run_reduce_background(script, args) do
    case System.cmd(script, args, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        Logger.warning("run_telemetry summary_materialize_failed exit=#{status} output=#{truncate(output)}")
    end
  end

  @doc """
  Synchronously materialize run-summaries and build rollups.

  Returns `{:ok, output}` on success or `{:error, reason}`. Used on daemon
  shutdown (bounded by `@materialize_timeout_ms`) and available to operators
  via the `analytics/reduce` tool.
  """
  @spec materialize(keyword()) :: {:ok, String.t()} | {:error, term()}
  def materialize(opts \\ []) do
    task = Task.async(fn -> run_reduce(opts) end)

    case Task.yield(task, Keyword.get(opts, :timeout_ms, @materialize_timeout_ms)) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _other -> {:error, :materialize_timeout}
    end
  end

  defp run_reduce(opts) do
    case reduce_command(opts) do
      {:ok, {script, args}} ->
        case System.cmd(script, args, stderr_to_stdout: true) do
          {output, 0} -> {:ok, output}
          {output, status} -> {:error, {:reduce_failed, status, truncate(output)}}
        end

      :unavailable ->
        {:error, :reduce_unavailable}
    end
  end

  @doc false
  @spec reduce_command(keyword()) :: {:ok, {Path.t(), [String.t()]}} | :unavailable
  def reduce_command(opts \\ []) do
    with {:ok, dir} <- reduce_dir(Keyword.get(opts, :reduce_dir)),
         script when is_binary(script) and script != "" <- Path.join(dir, @reduce_tool),
         true <- File.regular?(script),
         telemetry when is_binary(telemetry) and telemetry != "" <- telemetry_file(opts),
         state when is_binary(state) and state != "" <- state_node() do
      args = ["--all", "--all-builds", "--telemetry", telemetry, "--state-node", state]
      {:ok, {script, args}}
    else
      _other -> :unavailable
    end
  end

  defp telemetry_file(opts) do
    Keyword.get(opts, :telemetry_file) || RunTelemetry.telemetry_file()
  rescue
    _error -> nil
  end

  @doc false
  @spec reduce_dir(term()) :: {:ok, Path.t()} | {:error, term()}
  def reduce_dir(override) when is_binary(override), do: {:ok, Path.expand(override)}

  def reduce_dir(_override) do
    candidates =
      [Path.join(RepoBase.base_path(repo_url()), "analytics"), Path.expand("analytics")]
      |> Enum.reject(&is_nil/1)

    case Enum.find(candidates, &File.dir?/1) do
      nil -> {:error, :reduce_dir_not_found}
      dir -> {:ok, dir}
    end
  rescue
    _error -> {:error, :reduce_dir_not_found}
  end

  ## ---- reading ----

  @doc """
  Load one boot's materialized run-summary back into the reduced dataset shape
  the dashboard Presenter consumes. Returns `{:ok, dataset}` or
  `{:error, :missing | :invalid_summary}`.
  """
  @spec load_dataset(String.t()) :: {:ok, map()} | {:error, atom()}
  def load_dataset(boot_id) when is_binary(boot_id) do
    case File.read(run_summary_path(boot_id)) do
      {:ok, body} -> decode_summary(body)
      {:error, _reason} -> {:error, :missing}
    end
  end

  @doc "Loads every materialized prior boot (excluding the live boot) as datasets."
  @spec load_prior_datasets(String.t() | nil) :: [map()]
  def load_prior_datasets(current_boot) do
    summary_boot_ids()
    |> Enum.reject(&(&1 == current_boot))
    |> Enum.flat_map(fn boot_id ->
      case load_dataset(boot_id) do
        {:ok, dataset} -> [dataset]
        {:error, _reason} -> []
      end
    end)
  end

  @doc """
  Decodes a run-summary JSON body into the dataset shape `Dataset.build/2`
  produces, so the Presenter's model pipeline can render prior boots from
  summaries. String-keyed JSON records are re-keyed to the atom/string hybrid
  shape the reducer and renderers rely on (metric keys stay strings; envelope
  and lifecycle keys become atoms).
  """
  @spec decode_summary(String.t()) :: {:ok, map()} | {:error, atom()}
  def decode_summary(body) when is_binary(body) do
    with {:ok, decoded} <- Jason.decode(body),
         true <- is_map(decoded),
         {:ok, records} <- decode_records(Map.get(decoded, "records", [])),
         {:ok, restarts} <- decode_records(Map.get(decoded, "restarts", [])),
         {:ok, actors} <- decode_actors(Map.get(decoded, "actors", %{})),
         {:ok, tickets} <- decode_tickets(Map.get(decoded, "tickets", %{})) do
      {:ok,
       %{
         records: records,
         restarts: restarts,
         actors: actors,
         tickets: tickets,
         findings: Map.get(decoded, "findings", []),
         warnings: Map.get(decoded, "warnings", []),
         provenance: decode_provenance(Map.get(decoded, "provenance", %{}))
       }}
    else
      _other -> {:error, :invalid_summary}
    end
  end

  def decode_summary(_body), do: {:error, :invalid_summary}

  ## ---- decoders ----

  @resource_metrics ~w(
    cpu_percent rss_bytes fd_count read_bytes write_bytes
    read_bytes_per_second write_bytes_per_second
    system_fd_used system_fd_limit system_fd_available system_fd_headroom_ratio
  )

  defp decode_records(list) when is_list(list) do
    {:ok, Enum.map(list, &decode_record/1)}
  rescue
    _error -> {:error, :invalid_records}
  end

  defp decode_record(map) when is_map(map) do
    %{
      schema_version: Map.get(map, "schema_version"),
      kind: Map.get(map, "kind"),
      timestamp: Map.get(map, "timestamp"),
      timestamp_iso: Map.get(map, "timestamp_iso") || Map.get(map, "timestamp"),
      timestamp_ms: Map.get(map, "timestamp_ms"),
      recorded_at: Map.get(map, "recorded_at"),
      boot_id: Map.get(map, "boot_id"),
      sequence: Map.get(map, "sequence"),
      record_id: Map.get(map, "record_id"),
      attributes: Map.get(map, "attributes") || %{},
      source_path: Map.get(map, "source_path"),
      source_line: Map.get(map, "source_line")
    }
  end

  defp decode_actors(actors) when is_map(actors) do
    {:ok, Map.new(actors, fn {key, map} -> {key, decode_actor(map)} end)}
  rescue
    _error -> {:error, :invalid_actors}
  end

  defp decode_actor(map) when is_map(map) do
    %{
      actor: Map.get(map, "actor"),
      actor_type: Map.get(map, "actor_type"),
      samples: Enum.map(Map.get(map, "samples", []), &decode_sample/1),
      profile: decode_profile(Map.get(map, "profile", %{})),
      gaps: Map.get(map, "gaps", []),
      availability: atomize_keys(Map.get(map, "availability", %{}))
    }
  end

  defp decode_sample(map) when is_map(map) do
    metrics = Map.new(@resource_metrics, fn metric -> {metric, Map.get(map, metric)} end)

    Map.merge(metrics, %{
      actor: Map.get(map, "actor"),
      actor_type: Map.get(map, "actor_type"),
      ticket: Map.get(map, "ticket"),
      availability: Map.get(map, "availability"),
      unavailable_reason: Map.get(map, "unavailable_reason"),
      process_count: Map.get(map, "process_count"),
      partial_fields: Map.get(map, "partial_fields", []),
      timestamp: Map.get(map, "timestamp"),
      timestamp_ms: Map.get(map, "timestamp_ms"),
      boot_id: Map.get(map, "boot_id"),
      record_id: Map.get(map, "record_id")
    })
  end

  defp decode_profile(profile) when is_map(profile) do
    Map.new(profile, fn {metric, stats} -> {metric, decode_stats(stats)} end)
  end

  defp decode_stats(stats) when is_map(stats) do
    %{
      count: Map.get(stats, "count"),
      min: Map.get(stats, "min"),
      mean: Map.get(stats, "mean"),
      median: Map.get(stats, "median"),
      p95: Map.get(stats, "p95"),
      max: Map.get(stats, "max")
    }
  end

  defp decode_tickets(tickets) when is_map(tickets) do
    {:ok, Map.new(tickets, fn {key, map} -> {key, decode_ticket(map)} end)}
  rescue
    _error -> {:error, :invalid_tickets}
  end

  defp decode_ticket(map) when is_map(map) do
    %{
      ticket: Map.get(map, "ticket"),
      complexity: Map.get(map, "complexity"),
      events: Enum.map(Map.get(map, "events", []), &atomize_keys/1),
      intervals: Enum.map(Map.get(map, "intervals", []), &atomize_keys/1),
      findings: Map.get(map, "findings", [])
    }
  end

  defp decode_provenance(map) when is_map(map) do
    %{
      inputs: Map.get(map, "inputs", []),
      files: Map.get(map, "files", []),
      schema_versions: Map.get(map, "schema_versions", []),
      time_range: decode_time_range(Map.get(map, "time_range")),
      record_count: Map.get(map, "record_count", 0),
      enrich: Map.get(map, "enrich", false),
      generated_by: Map.get(map, "generated_by")
    }
  end

  defp decode_time_range(%{"start" => start, "end" => finish}) when is_binary(start) and is_binary(finish),
    do: %{start: start, end: finish}

  defp decode_time_range(_other), do: nil

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) ->
        case safe_existing_atom(key) do
          {:ok, atom} -> {atom, value}
          :error -> {key, value}
        end

      {key, value} ->
        {key, value}
    end)
  end

  # Only keys already present as atoms in the running system are converted;
  # anything else stays a string key. Summary JSON is machine-local and written
  # by our own tool, but this keeps a corrupt summary from minting atoms.
  defp safe_existing_atom(key) do
    {:ok, String.to_existing_atom(key)}
  rescue
    ArgumentError -> :error
  end

  defp truncate(output) when is_binary(output) and byte_size(output) > 2000,
    do: binary_part(output, 0, 2000) <> "…"

  defp truncate(output), do: output
end
