defmodule Aiur.ModelDiscovery do
  @moduledoc """
  Asks an OpenAI-compatible provider's own HTTP catalogue which models it
  currently serves, and caches the answer beside the other runtime JSON state.

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

  alias Aiur.{CodingAgent, Config, Workflow}
  alias Aiur.Usage.PriceTable

  @cache_file "model-catalog.json"
  @cache_version 1
  @ttl_seconds 86_400
  @request_timeout_ms 30_000
  # A fetched price within 5% of the curated one is rounding or a mid-day
  # revision, not the kind of staleness worth waking an operator for.
  @drift_threshold Decimal.new("0.05")

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
      _other -> empty_state()
    end
  end

  def load(_path), do: empty_state()

  @doc "Whether the registry declares a catalogue endpoint for this backend."
  @spec discoverable?(CodingAgent.backend()) :: boolean()
  def discoverable?(backend), do: not is_nil(source_module(backend))

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
    backend |> entry(opts) |> Map.get("models", []) |> Enum.filter(&is_map/1)
  end

  @doc "Identifiers refused at ingest, each with the reason it was refused."
  @spec rejected(CodingAgent.backend(), keyword()) :: [rejection()]
  def rejected(backend, opts \\ []) do
    backend |> entry(opts) |> Map.get("rejected", []) |> Enum.filter(&is_map/1)
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

    case backend |> entry(opts) |> Map.get("fetched_at") |> parse_time() do
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
    with {:ok, source} <- fetch_source(backend),
         {:ok, request} <- source.request(instance(backend), api_key(backend, opts)),
         {:ok, body} <- fetch(request, opts),
         {:ok, models} <- source.parse(body) do
      {kept, refused} = ingest(models)
      report(backend, kept, refused, opts)
      write_entry(backend, kept, refused, opts)
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
    if stale?(backend, opts), do: refresh(backend, opts), else: {:ok, :fresh}
  end

  @doc """
  Discovered ids with no curated price row at all, for the given date. Usage on
  these is priced as unknown, never as zero.
  """
  @spec unpriced_models(CodingAgent.backend(), keyword()) :: [String.t()]
  def unpriced_models(backend, opts \\ []) do
    with {:ok, catalog} <- price_catalog(opts),
         provider when is_atom(provider) <- price_provider(backend, catalog) do
      priced = MapSet.new(catalog.entries, & &1.resolved_model)

      backend
      |> cached_models(opts)
      |> Enum.reject(&MapSet.member?(priced, &1))
    else
      _other -> cached_models(backend, opts)
    end
  end

  @doc """
  Advisory comparison of the prices the provider quoted against the curated
  table, for models and dimensions both of them carry.

  Returns one entry per disagreement larger than `threshold:` (a relative
  difference, default 5%). It never mutates anything: a drift is evidence that
  a curated row needs reviewing, not permission for a vendor feed to rewrite
  billing.
  """
  @spec price_drift(CodingAgent.backend(), keyword()) :: [map()]
  def price_drift(backend, opts \\ []) do
    with {:ok, catalog} <- price_catalog(opts),
         provider when is_atom(provider) <- price_provider(backend, catalog) do
      on = Keyword.get_lazy(opts, :on, &Date.utc_today/0)
      threshold = Keyword.get(opts, :threshold, @drift_threshold)

      backend
      |> cached_entries(opts)
      |> Enum.flat_map(&model_drift(&1, catalog, provider, on, threshold))
    else
      _other -> []
    end
  end

  defp model_drift(model, catalog, provider, on, threshold) do
    id = Map.get(model, "id")

    model
    |> Map.get("pricing", %{})
    |> Enum.flat_map(fn {dimension, quoted} ->
      drift_entry(catalog, provider, id, dimension, quoted, on, threshold)
    end)
  end

  defp drift_entry(catalog, provider, id, dimension, quoted, on, threshold) do
    with %Decimal{} = discovered <- decimal(quoted),
         %{price: curated} <- curated_price(catalog, provider, id, dimension, on),
         %Decimal{} = drift <- relative_drift(curated, discovered),
         :gt <- Decimal.compare(drift, threshold) do
      [
        %{
          provider: provider,
          resolved_model: id,
          token_dimension: dimension,
          curated: curated,
          discovered: discovered,
          relative_drift: drift
        }
      ]
    else
      _other -> []
    end
  end

  # The exact-join `PriceTable.lookup/2` needs dimensions a catalogue feed does
  # not report (relationship revision, cache-write duration). Drift is advisory,
  # so it reads the series directly: newest revision in force on `on`.
  defp curated_price(catalog, provider, model, dimension, on) do
    catalog.entries
    |> Enum.filter(&curated_match?(&1, provider, model, dimension, on))
    |> Enum.sort_by(& &1.effective_date, Date)
    |> List.last()
  end

  defp curated_match?(entry, provider, model, dimension, on) do
    entry.provider == provider and entry.resolved_model == model and
      Atom.to_string(entry.token_dimension) == to_string(dimension) and
      Date.compare(entry.effective_date, on) in [:lt, :eq]
  end

  # Scaled by the larger of the two rather than by the curated one, so a curated
  # row that says "free" and a quote that says otherwise reads as 100% drift
  # instead of dividing by zero and going silent.
  defp relative_drift(curated, discovered) do
    scale = Decimal.max(Decimal.abs(curated), Decimal.abs(discovered))

    if Decimal.equal?(scale, 0) do
      Decimal.new(0)
    else
      curated |> Decimal.sub(discovered) |> Decimal.abs() |> Decimal.div(scale)
    end
  end

  defp price_catalog(opts) do
    case Keyword.get(opts, :price_table) do
      %{entries: _entries} = catalog -> {:ok, catalog}
      nil -> PriceTable.default()
      _other -> {:error, :invalid_price_table}
    end
  end

  # The price table keys on a provider atom that equals the backend family.
  # Matching against atoms the catalog already holds means no atom is created
  # from a backend name, and an unpriced provider simply has no match.
  defp price_provider(backend, catalog) do
    family = CodingAgent.family_for(backend) || backend

    catalog.entries
    |> Enum.map(& &1.provider)
    |> Enum.find(&(Atom.to_string(&1) == family))
  end

  defp ingest(models) do
    {kept, refused} =
      Enum.reduce(models, {[], []}, fn model, {kept, refused} ->
        case rejection_reason(Map.get(model, :id)) do
          nil -> {[encode_model(model) | kept], refused}
          reason -> {kept, [%{"id" => inspect_id(Map.get(model, :id)), "reason" => to_string(reason)} | refused]}
        end
      end)

    {Enum.reverse(kept), Enum.reverse(refused)}
  end

  defp rejection_reason(id) when is_binary(id) do
    cond do
      String.trim(id) == "" -> :empty_identifier
      String.starts_with?(id, "~") -> :unstable_identifier_prefix
      String.contains?(id, ":") -> :reserved_routing_separator
      true -> nil
    end
  end

  defp rejection_reason(_id), do: :invalid_identifier

  defp inspect_id(id) when is_binary(id), do: id
  defp inspect_id(id), do: inspect(id)

  defp encode_model(model) do
    model
    |> Map.new(fn {key, value} -> {to_string(key), encode_value(value)} end)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp encode_value(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp encode_value(%{} = value), do: Map.new(value, fn {key, inner} -> {to_string(key), encode_value(inner)} end)
  defp encode_value(value), do: value

  defp fetch_source(backend) do
    case source_module(backend) do
      nil -> {:error, {:model_discovery_unsupported, backend}}
      module -> {:ok, module}
    end
  end

  defp source_module(backend) do
    case get_in(CodingAgent.backends(), [backend, :openai_compat, :models_endpoint]) do
      module when is_atom(module) and not is_nil(module) -> module
      _other -> nil
    end
  end

  defp instance(backend), do: get_in(CodingAgent.backends(), [backend, :openai_compat]) || %{}

  defp api_key(backend, opts) do
    fetcher = Keyword.get(opts, :api_key_fetcher, &System.get_env/1)

    case backend |> instance() |> Map.get(:api_key_env) do
      env when is_binary(env) -> fetcher.(env)
      _other -> nil
    end
  end

  defp fetch(request, opts) do
    fetch_fun = Keyword.get(opts, :fetch, &default_fetch/1)

    case fetch_fun.(request) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:model_catalog_status, status}}
      {:error, reason} -> {:error, {:model_catalog_request, reason}}
      other -> {:error, {:model_catalog_request, other}}
    end
  end

  defp default_fetch(%{url: url, headers: headers}) do
    case Req.get(url, headers: headers, receive_timeout: @request_timeout_ms, retry: false) do
      {:ok, response} -> {:ok, %{status: response.status, body: response.body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp entry(backend, opts) do
    state = Keyword.get_lazy(opts, :state, fn -> load(cache_path(opts)) end)

    case get_in(state, ["backends", backend]) do
      %{} = entry -> entry
      _other -> %{}
    end
  end

  defp cache_path(opts), do: Keyword.get(opts, :path, path())

  defp write_entry(backend, models, refused, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    result = %{models: models, rejected: refused}

    case cache_path(opts) do
      nil ->
        {:ok, result}

      path ->
        :global.trans({__MODULE__, path}, fn -> persist(path, backend, models, refused, now) end)
        {:ok, result}
    end
  end

  defp persist(path, backend, models, refused, now) do
    state = load(path)
    backends = Map.get(state, "backends", %{})

    entry = %{
      "fetched_at" => DateTime.to_iso8601(now),
      "models" => models,
      "rejected" => refused
    }

    write(path, %{
      "version" => @cache_version,
      "backends" => Map.put(backends, backend, entry)
    })
  end

  defp write(path, state) do
    File.mkdir_p(Path.dirname(path))
    tmp = path <> ".#{System.unique_integer([:positive])}.tmp"

    case File.write(tmp, Jason.encode!(state, pretty: true) <> "\n") do
      :ok -> File.rename(tmp, path)
      {:error, _reason} = error -> error
    end
  end

  defp report(backend, models, refused, opts) do
    Logger.info(
      "model discovery (#{backend}): #{length(models)} models, #{length(refused)} refused" <>
        rejection_summary(refused)
    )

    report_unpriced(backend, models, opts)
    Enum.each(price_drift(backend, Keyword.put(opts, :state, provisional_state(backend, models))), &warn_drift/1)
  end

  defp report_unpriced(backend, models, opts) do
    case unpriced_models(backend, Keyword.put(opts, :state, provisional_state(backend, models))) do
      [] ->
        :ok

      unpriced ->
        Logger.warning(
          "model discovery (#{backend}): #{length(unpriced)} discovered models have no curated price row " <>
            "(#{preview(unpriced)}). They stay usable; their usage reports unknown cost, never zero."
        )
    end
  end

  defp warn_drift(drift) do
    Logger.warning(
      "model discovery price drift (#{drift.provider} #{drift.resolved_model} #{drift.token_dimension}): " <>
        "curated #{Decimal.to_string(drift.curated, :normal)} vs provider-quoted " <>
        "#{Decimal.to_string(drift.discovered, :normal)} per million tokens. The curated row is still in force — " <>
        "review it, aiur will not overwrite it."
    )
  end

  # Report against what was just fetched rather than re-reading the file, so the
  # numbers logged are the ones this refresh saw.
  defp provisional_state(backend, models) do
    %{"backends" => %{backend => %{"models" => models}}}
  end

  defp rejection_summary([]), do: ""

  defp rejection_summary(refused) do
    summary =
      refused
      |> Enum.frequencies_by(&Map.get(&1, "reason"))
      |> Enum.map_join(", ", fn {reason, count} -> "#{reason}: #{count}" end)

    " (#{summary})"
  end

  defp preview(ids), do: ids |> Enum.take(5) |> Enum.join(", ")

  defp maybe_refresh_async(backend, opts) do
    if refresh_requested?(opts) and discoverable?(backend) and enabled?(backend, opts) and
         stale?(backend, opts) do
      start_refresh(backend, opts)
    end

    :ok
  end

  # `:model_discovery_refresh?` is the application-level kill switch, set false
  # under `:test` so no test can reach a provider over the network through the
  # lazy path. Discovery's own tests drive `refresh/2` with an injected fetcher.
  defp refresh_requested?(opts) do
    Keyword.get(opts, :refresh, true) and Application.get_env(:aiur, :model_discovery_refresh?, true)
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
    case :global.trans({{__MODULE__, backend}, self()}, fn -> log_refresh(backend, opts) end, [node()], 0) do
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

  defp decimal(%Decimal{} = value), do: value

  defp decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> decimal
      _other -> nil
    end
  end

  defp decimal(value) when is_integer(value), do: Decimal.new(value)
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)
  defp decimal(_value), do: nil

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _offset} -> time
      _other -> nil
    end
  end

  defp parse_time(_value), do: nil

  defp empty_state, do: %{"version" => @cache_version, "backends" => %{}}
end
