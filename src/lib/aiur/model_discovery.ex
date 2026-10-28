defmodule Aiur.ModelDiscovery do
  @moduledoc """
  Asks a backend which models it currently serves — an OpenAI-compatible
  provider's HTTP catalogue, or a coding-agent CLI's `model/list`
  (`Aiur.ModelCatalog`) — and caches the answer beside the other runtime JSON
  state. The CLI answer is what lets a `model:` label name a model released
  after this build of aiur.

  ## What this does and does not replace

  It does **not** replace curation. `Aiur.CodingAgent.backends/0` keeps owning
  everything that is a judgement call — reasoning-effort vocabularies,
  capability flags, derived family aliases, presentation, which models `aiur
  init` offers, and the operator's own naming. Discovery only ever *adds*
  identifiers to the set aiur will accept without complaint. Where a discovered
  id collides with a curated one, the curated metadata wins by construction:
  nothing here writes to the registry, and the merge in `models_for/2` puts the
  curated list first and appends only what is new.

  ## Cold start, offline

  The cache is a hint, never a dependency. With no cache file and no network
  the discovered set is empty and `models_for/2` returns exactly the registry's
  curated list — that is, aiur behaves precisely as it did before this module
  existed. A corrupt or truncated cache is treated the same way as an absent
  one (permissive decode, same as `Aiur.ModelAvailability.load/1`).

  ## Never on the validation path

  Config validation must never make a network call, and never does: it reads
  `cached_models/2`, which only ever touches the file. An absent or stale cache
  means "cannot verify", and a model aiur cannot verify is **accepted**, not
  rejected — aiur's list is expected to lag the provider, so an unrecognized
  model is far more likely new than wrong. Refresh is lazy and backgrounded off
  `models_for/2`, gated on a 24-hour TTL.

  ## Identifiers aiur refuses to ingest

  Two classes of OpenRouter id are rejected at ingest, with the reason recorded
  in the cache under `"rejected"`:

    * `:reserved_routing_separator` — an id containing `:`
      (`moonshotai/kimi-k2.7-code:batch`). Aiur routing values are
      `backend:model:effort`, so admitting one would make
      `openrouter:moonshotai/kimi-k2.7-code:batch` parse `batch` as a
      reasoning effort. This is fatal, not cosmetic.
    * `:unstable_identifier_prefix` — an id starting with `~`
      (`~moonshotai/kimi-latest`), OpenRouter's marker for a non-canonical
      pointer rather than an addressable model.

  ## Pricing is advisory

  OpenRouter is the one surveyed catalogue that quotes prices. Those numbers
  are recorded in the cache and compared against the curated table by
  `price_drift/2`, and they stop there. They are never written into
  `Aiur.Usage.PriceTable`, and a curated row always wins.

  This is deliberate. Wiring a vendor feed straight into billing would let an
  upstream edit silently rewrite what aiur reports having spent, including
  retroactively. A drift warning gets the same value — a stale curated row
  under-reporting real spend becomes something the operator can *see* — without
  handing the numbers over. The alternative, ingesting fetched prices as
  effective-dated revisions so history stays correctly valued, stays open as a
  deliberate follow-up; it needs a review step that this module does not have.

  A discovered model with no curated row is **usable but visibly unpriced**:
  `Aiur.Usage.PriceTable.lookup/2` misses with `:unknown_price_model`, which
  `Aiur.Usage.Pricing` carries through as an unknown API-equivalent estimate
  with that coverage reason. It is never costed at zero. `unpriced_models/2`
  names them, and a refresh logs them.
  """

  require Logger

  alias Aiur.{CodingAgent, Config, ModelCatalog, Workflow}
  alias Aiur.ModelDiscovery.{Cache, Fetch, PriceDrift, Report}

  @cache_file "model-catalog.json"
  @ttl_seconds 86_400
  # A refresh attempt — success or failure — holds the next one off for this
  # long, so a missing CLI or a typo'd label cannot trigger a probe per poll.
  @cooldown_seconds 600
  # Wall-clock budget for `refresh_now/2`; matches the CLI probe's own timeout.
  @refresh_now_timeout_ms 20_000
  # A fetched price within 5% of the curated one is rounding or a mid-day
  # revision, not the kind of staleness worth waking an operator for.

  @type model :: %{String.t() => term()}
  @type rejection :: %{String.t() => String.t()}

  @doc """
  Path of the catalogue cache — `model-catalog.json`, a sibling of the active
  workflow config and of `model-usage.json`. `nil` when no config is resolvable
  (the wizard runs before one exists), which every reader treats as an empty
  cache.
  """
  @spec path() :: Path.t() | nil
  def path do
    Path.join(Path.dirname(Workflow.workflow_file_path()), @cache_file)
  rescue
    _error -> nil
  end

  @doc "Whole cache document. A missing, unreadable, or corrupt file reads as empty."
  @spec load(Path.t() | nil) :: map()
  def load(path \\ path())

  def load(path) when is_binary(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"backends" => %{}} = state} <- Jason.decode(body) do
      state
    else
      _other -> Cache.empty_state()
    end
  end

  def load(_path), do: Cache.empty_state()

  @doc """
  Whether aiur can ask this backend which models it serves: an
  OpenAI-compatible catalogue endpoint, or a CLI that answers `model/list`
  (`Aiur.ModelCatalog`).
  """
  @spec discoverable?(CodingAgent.backend()) :: boolean()
  def discoverable?(backend), do: not is_nil(Fetch.source_module(backend)) or cli_catalogue?(backend)

  @doc """
  The cache key a backend's catalogue lives under. Backends that share a CLI
  (`claude-repl` probes `claude`) share one entry, declared by the registry's
  `model_catalog_backend`.
  """
  @spec source_key(CodingAgent.backend()) :: CodingAgent.backend()
  def source_key(backend) do
    case CodingAgent.backends()[backend] do
      %{model_catalog_backend: source} when is_binary(source) -> source
      _entry -> backend
    end
  end

  @doc """
  Every id aiur will match a label against on this backend — the curated
  registry list first, then discovered ids — tagged with whether a catalogue
  has ever been discovered for it. `:curated_only` means the backend could be
  asked and never answered, so an unmatched name may simply be too new.
  Cache-only: never fetches and never schedules a refresh, so it is safe on
  the orchestrator's hot paths.
  """
  @spec catalogue(CodingAgent.backend(), keyword()) :: {[String.t()], :discovered | :curated_only}
  def catalogue(backend, opts \\ []) do
    curated = CodingAgent.seedable_models(backend)
    entry = Cache.entry(backend, opts)
    discovered = entry |> Map.get("models", []) |> Enum.flat_map(&List.wrap(Map.get(&1, "id")))

    {curated ++ (discovered -- curated), provenance(backend, entry, opts)}
  end

  # Only a CLI catalogue can make an unmatched bare name "possibly too new":
  # bare names never resolve through an HTTP catalogue's families.
  defp provenance(backend, entry, opts) do
    if cli_catalogue?(backend) and enabled?(backend, opts) and is_nil(Map.get(entry, "fetched_at")),
      do: :curated_only,
      else: :discovered
  end

  @doc """
  Discovered model ids for a backend, read from the cache only. Never fetches,
  never triggers a refresh — this is the function anything on the config
  validation path may call.
  """
  @spec cached_models(CodingAgent.backend(), keyword()) :: [String.t()]
  def cached_models(backend, opts \\ []) do
    backend |> cached_entries(opts) |> Enum.flat_map(&List.wrap(Map.get(&1, "id")))
  end

  @doc "Discovered model records (id plus whatever metadata the provider reported)."
  @spec cached_entries(CodingAgent.backend(), keyword()) :: [model()]
  def cached_entries(backend, opts \\ []) do
    backend |> Cache.entry(opts) |> Map.get("models", []) |> Enum.filter(&is_map/1)
  end

  @doc "Identifiers refused at ingest, each with the reason it was refused."
  @spec rejected(CodingAgent.backend(), keyword()) :: [rejection()]
  def rejected(backend, opts \\ []) do
    backend |> Cache.entry(opts) |> Map.get("rejected", []) |> Enum.filter(&is_map/1)
  end

  @doc """
  Every model id usable on a backend: the registry's curated list first, then
  the discovered ids it does not already contain.

  Reading this is what schedules a background refresh when the cache is older
  than the TTL. The refresh never blocks the caller and its failure is never
  the caller's problem — a stale or absent cache degrades to the curated list.
  """
  @spec models_for(CodingAgent.backend(), keyword()) :: [String.t()]
  def models_for(backend, opts \\ []) do
    maybe_refresh_async(backend, opts)
    curated = CodingAgent.seedable_models(backend)
    curated ++ (cached_models(backend, opts) -- curated)
  end

  @doc """
  Whether a model is one this build knows for a backend, counting both the
  curated registry list and the discovered cache. As with
  `Aiur.CodingAgent.known_model?/2`, a `false` answer means "not in any list
  aiur holds", never "invalid".
  """
  @spec known_model?(CodingAgent.backend(), term(), keyword()) :: boolean()
  def known_model?(backend, model, opts \\ [])
  def known_model?(backend, model, opts) when is_binary(model), do: model in models_for(backend, opts)
  def known_model?(_backend, _model, _opts), do: false

  @doc "Whether the cached catalogue is absent or older than the 24-hour TTL."
  @spec stale?(CodingAgent.backend(), keyword()) :: boolean()
  def stale?(backend, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    case backend |> Cache.entry(opts) |> Map.get("fetched_at") |> parse_time() do
      %DateTime{} = fetched_at -> DateTime.diff(now, fetched_at, :second) >= @ttl_seconds
      nil -> true
    end
  end

  @doc """
  Fetches, ingests, and caches the provider's catalogue.

  Pass `fetch: fun` to supply the response instead of making a request; the
  function receives `%{url: url, headers: headers}` and returns
  `{:ok, %{status: status, body: body}}` or `{:error, reason}` — the same seam
  `Aiur.Codeowners` uses for the GitHub API.
  """
  @spec refresh(CodingAgent.backend(), keyword()) ::
          {:ok, %{models: [model()], rejected: [rejection()]}} | {:error, term()}
  def refresh(backend, opts \\ []) do
    result = if cli_catalogue?(backend), do: refresh_cli(backend, opts), else: refresh_http(backend, opts)

    with {:error, _reason} <- result do
      Cache.record_attempt(backend, opts)
      result
    end
  end

  defp refresh_http(backend, opts) do
    with {:ok, source} <- Fetch.fetch_source(backend),
         {:ok, request} <- source.request(Fetch.instance(backend), Fetch.api_key(backend, opts)),
         {:ok, body} <- Fetch.fetch(request, opts),
         {:ok, models} <- source.parse(body) do
      {kept, refused} = Fetch.ingest(models)
      Report.report(backend, kept, refused, opts)
      Cache.write_entry(backend, kept, refused, opts)
    end
  end

  # A CLI backend answers `model/list` over its own app-server
  # (`Aiur.ModelCatalog`). It carries ids only, so the price reporting the
  # HTTP catalogues get has nothing to compare and is skipped.
  defp refresh_cli(backend, opts) do
    discover = Keyword.get(opts, :discover, &ModelCatalog.discover/1)

    with {:ok, ids} <- safe_discover(discover, source_key(backend)) do
      {kept, refused} = Fetch.ingest(Enum.map(ids, &%{id: &1}))
      Logger.info("model discovery (#{source_key(backend)}): #{length(kept)} models, #{length(refused)} refused")
      Cache.write_entry(backend, kept, refused, opts)
    end
  end

  # A CLI that dies at startup can make the port calls raise or exit. That is a
  # failed attempt like any other — recorded, cooled down — never a crash in
  # the agent runner that asked.
  defp safe_discover(discover, key) do
    discover.(key)
  rescue
    error -> {:error, {:discover_crashed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:discover_crashed, {kind, reason}}}
  end

  @doc """
  Refreshes now, inside the caller, unless the backend was tried within the
  cooldown. Returns `{:ok, :cooldown}` when skipped, `{:ok, :disabled}` when the
  operator switched discovery off or the backend has no catalogue, and never
  takes longer than the probe budget.
  """
  @spec refresh_now(CodingAgent.backend(), keyword()) :: {:ok, term()} | {:error, term()}
  def refresh_now(backend, opts \\ []) do
    if discoverable?(backend) and enabled?(backend, opts) and refresh_allowed?(opts),
      do: :global.trans(lock_id(backend), fn -> refresh_unless_cooling(backend, opts) end, [node()]),
      else: {:ok, :disabled}
  end

  # Runners that start together wait on one lock per catalogue, then find the
  # attempt the first one stamped and skip — one probe, not one per runner.
  defp refresh_unless_cooling(backend, opts) do
    if cooling_down?(backend, opts), do: {:ok, :cooldown}, else: bounded_refresh(backend, opts)
  end

  defp lock_id(backend), do: {{__MODULE__, source_key(backend)}, self()}

  defp bounded_refresh(backend, opts) do
    task = Task.async(fn -> contained_refresh(backend, opts) end)

    case Task.yield(task, Keyword.get(opts, :timeout_ms, @refresh_now_timeout_ms)) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> timed_out(backend, opts)
    end
  end

  # The refresh runs in a linked task; anything it raises is a failed attempt,
  # never a crash in the process that asked.
  defp contained_refresh(backend, opts) do
    refresh(backend, opts)
  rescue
    error ->
      Cache.record_attempt(backend, opts)
      {:error, {:refresh_crashed, Exception.message(error)}}
  catch
    kind, reason ->
      Cache.record_attempt(backend, opts)
      {:error, {:refresh_crashed, {kind, reason}}}
  end

  defp timed_out(backend, opts) do
    Cache.record_attempt(backend, opts)
    {:error, :refresh_timeout}
  end

  @doc """
  Whether a refresh would run now: the catalogue is stale *and* the backend was
  not tried within the cooldown. Both the background refresh and
  `refresh_now/2` check this, so a CLI that is missing or broken is probed at
  most once per cooldown window rather than once per caller.
  """
  @spec refresh_due?(CodingAgent.backend(), keyword()) :: boolean()
  def refresh_due?(backend, opts \\ []), do: stale?(backend, opts) and not cooling_down?(backend, opts)

  defp cooling_down?(backend, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    case backend |> Cache.entry(opts) |> Map.get("last_attempt_at") |> parse_time() do
      %DateTime{} = attempted -> DateTime.diff(now, attempted, :second) < @cooldown_seconds
      nil -> false
    end
  end

  @doc """
  `refresh/2` when the cache is stale, `{:ok, :fresh}` when it is not. This is
  what the background task runs; it re-checks staleness so a stampede of
  readers costs at most one request.
  """
  @spec refresh_stale(CodingAgent.backend(), keyword()) ::
          {:ok, %{models: [model()], rejected: [rejection()]}} | {:ok, :fresh} | {:error, term()}
  def refresh_stale(backend, opts \\ []) do
    if refresh_due?(backend, opts), do: refresh(backend, opts), else: {:ok, :fresh}
  end

  @doc """
  Discovered ids with no curated price row at all, for the given date. Usage on
  these is priced as unknown, never as zero.
  """
  @spec unpriced_models(CodingAgent.backend(), keyword()) :: [String.t()]
  defdelegate unpriced_models(backend, opts \\ []), to: PriceDrift

  @doc """
  Advisory comparison of the prices the provider quoted against the curated
  table, for models and dimensions both of them carry.

  Returns one entry per disagreement larger than `threshold:` (a relative
  difference, default 5%). It never mutates anything: a drift is evidence that
  a curated row needs reviewing, not permission for a vendor feed to rewrite
  billing.
  """
  @spec price_drift(CodingAgent.backend(), keyword()) :: [map()]
  defdelegate price_drift(backend, opts \\ []), to: PriceDrift

  defp maybe_refresh_async(backend, opts) do
    if refresh_requested?(opts) and background_refresh_due?(backend, opts), do: start_refresh(backend, opts)
    :ok
  end

  @doc """
  Whether reading `models_for/2` would start a background refresh, ignoring the
  application kill switch: the backend is discoverable, not opted out, stale,
  and not tried within the cooldown.
  """
  @spec background_refresh_due?(CodingAgent.backend(), keyword()) :: boolean()
  def background_refresh_due?(backend, opts \\ []),
    do: discoverable?(backend) and enabled?(backend, opts) and refresh_due?(backend, opts)

  # `:model_discovery_refresh?` is the application-level kill switch, set false
  # under `:test` so no test can reach a provider over the network through the
  # lazy path. Discovery's own tests drive `refresh/2` with an injected fetcher.
  defp refresh_requested?(opts) do
    Keyword.get(opts, :refresh, true) and Application.get_env(:aiur, :model_discovery_refresh?, true)
  end

  # `refresh_now/2` honours the same kill switch, except when the caller
  # injected its own source: that is a test driving the path explicitly.
  defp refresh_allowed?(opts) do
    Keyword.has_key?(opts, :discover) or Keyword.has_key?(opts, :fetch) or
      Application.get_env(:aiur, :model_discovery_refresh?, true)
  end

  @doc "Whether this backend's model list comes from its own CLI's `model/list`."
  @spec cli_catalogue?(CodingAgent.backend()) :: boolean()
  def cli_catalogue?(backend) do
    case CodingAgent.backends()[backend] do
      %{model_catalog: extract} when is_function(extract, 1) -> is_nil(Fetch.source_module(backend))
      _entry -> false
    end
  end

  defp start_refresh(backend, opts) do
    task_opts = Keyword.drop(opts, [:state])

    if Process.whereis(Aiur.TaskSupervisor) do
      Task.Supervisor.start_child(Aiur.TaskSupervisor, fn -> guarded_refresh(backend, task_opts) end)
    end

    :ok
  end

  # `:global.trans/4` with zero retries makes a concurrent refresh a no-op
  # rather than a queued duplicate request: a held lock returns `:aborted`
  # immediately instead of queueing a second request for the same catalogue.
  #
  # The lock id must be the two-element `{resource_id, lock_requester_id}` that
  # `:global` documents — the backend belongs inside the resource half, not as
  # a third element, or the call can never succeed.
  defp guarded_refresh(backend, opts) do
    case :global.trans(lock_id(backend), fn -> log_refresh(backend, opts) end, [node()], 0) do
      :aborted -> :ok
      result -> result
    end
  end

  defp log_refresh(backend, opts) do
    case refresh_stale(backend, opts) do
      {:error, reason} -> Logger.info("model discovery (#{backend}) skipped: #{inspect(reason)}")
      _ok -> :ok
    end
  end

  # An operator switches discovery off per backend with
  # `agent.backend_configs.<backend>.model_discovery = false`. An unreadable
  # config (the wizard runs before one exists) means "not switched off".
  defp enabled?(backend, opts) do
    case Keyword.get(opts, :enabled) do
      value when is_boolean(value) -> value
      _other -> configured_enabled?(backend)
    end
  end

  defp configured_enabled?(backend) do
    Config.backend_config(backend)["model_discovery"] != false
  rescue
    _error -> true
  end

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _offset} -> time
      _other -> nil
    end
  end

  defp parse_time(_value), do: nil
end
