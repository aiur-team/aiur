defmodule Aiur.ModelAvailability do
  @moduledoc """
  Durable observations used by the opt-in model rate-limit fallback.

  The ledger is deliberately a plain JSON file beside the active workflow
  configuration (`model-usage.json`). It is both restart-safe and easy for an
  Executor to inspect without querying a running node. Providers may report a
  subset of the hourly, weekly, and monthly windows; unknown windows never
  make a backend unavailable.

  A usage-limit refusal that repeats for the same backend soon after the last
  one backs off: the second refusal holds the backend for 10 minutes, and each
  later one doubles the hold, to at most the one-hour unknown-reset rule
  (`backoff_until`). A provider that still refuses after its printed reset
  cannot make the fallback resume, fail and resume again every tick (#2737).
  A later reset from the provider still wins.

  A repeat means a refusal that *disproves* the last printed reset, so it has to
  arrive at or after it. Refusals that arrive before it are the same limit seen
  by other agents, and they never extend the hold. That is what keeps one
  fleet-wide limit from holding a backend for an hour past its own reset.
  """

  alias Aiur.{CodexProber, CodingAgent, Workflow}
  alias Aiur.Config.RoutingValue
  alias Aiur.ModelAvailability.Limits

  # Stale threshold: refresh cached limit when older than 5 minutes
  @stale_threshold_seconds 300
  # Retry delay: reschedule probe after 2 minutes on failure
  @retry_delay_seconds 120

  @spec path() :: Path.t()
  def path, do: Path.join(Path.dirname(Workflow.workflow_file_path()), "model-usage.json")

  @spec load(Path.t()) :: map()
  def load(path \\ path()) do
    with {:ok, body} <- File.read(path),
         {:ok, %{} = state} <- Jason.decode(body) do
      state
    else
      _ -> %{"backends" => %{}}
    end
  end

  @spec observe(String.t(), map() | nil, keyword()) :: :ok | {:error, term()}
  def observe(backend, limits, opts \\ []) when is_binary(backend) do
    backend = backend_key(backend)
    path = Keyword.get(opts, :path, path())
    now = Keyword.get(opts, :now, DateTime.utc_now())

    :global.trans({__MODULE__, path}, fn ->
      state = load(path)
      backends = Map.get(state, "backends", %{})
      normalized = Limits.normalize_limits(limits)

      entry =
        normalized
        |> Limits.add_unknown_reset_deadlines(now)
        |> Limits.merge_entry(Map.get(backends, backend, %{}))
        |> Map.put("observed_at", DateTime.to_iso8601(now))
        |> Limits.record_limit_streak(Map.get(backends, backend, %{}), normalized, now, opts)
        |> Limits.record_observation(normalized, now)

      write(path, Map.put(state, "backends", Map.put(backends, backend, entry)))
    end)
  end

  @spec mark_limited(String.t(), String.t() | nil, keyword()) :: :ok | {:error, term()}
  def mark_limited(backend, reset_at \\ nil, opts \\ []) when is_binary(backend) do
    observe(backend, %{"limited" => true, "reset_at" => reset_at}, opts)
  end

  @doc """
  The ledger key for a backend **or a full route**. A route is reduced to its
  backend first, because a usage limit is an account-level fact: every
  `openrouter:*` route shares one OpenRouter account and one quota, so they
  share one entry. Keying on the route instead would let a limit observed on
  one model leave the same exhausted account looking available under another.

  Reducing to the backend family is also what keeps direct and via-OpenRouter
  routes to the *same* model independent — `claude` keys on `claude` and
  `openrouter:anthropic/claude-sonnet-5` keys on `openrouter` — so a
  first-party 429 never marks the OpenRouter route limited.
  """
  @spec backend_key(String.t()) :: String.t()
  def backend_key(backend) do
    backend = RoutingValue.routing_backend(backend) || backend

    case CodingAgent.family_for(backend) do
      family when is_binary(family) -> family
      _ -> backend
    end
  end

  @spec available?(String.t(), keyword()) :: boolean()
  def available?(backend, opts \\ []) when is_binary(backend) do
    backend = backend_key(backend)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    entry = Keyword.get(opts, :state, load(Keyword.get(opts, :path, path()))) |> get_in(["backends", backend]) || %{}

    not Limits.limited?(entry, now)
  end

  @doc "Whether availability is backed by a positive observation or a real elapsed reset."
  @spec recovery_confirmed?(String.t(), keyword()) :: boolean()
  def recovery_confirmed?(backend, opts \\ []) when is_binary(backend) do
    backend = backend_key(backend)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    state = Keyword.get(opts, :state, load(Keyword.get(opts, :path, path())))
    entry = get_in(state, ["backends", backend]) || %{}

    available?(backend, Keyword.put(opts, :state, state)) and
      (Limits.positive_observation_after_limit?(entry) or Limits.elapsed_real_reset?(entry, now))
  end

  @spec first_available([String.t()], keyword()) :: String.t() | nil
  def first_available(backends, opts \\ []) when is_list(backends) do
    state = Keyword.get(opts, :state, load(Keyword.get(opts, :path, path())))
    Enum.find(backends, &available?(&1, Keyword.put(opts, :state, state)))
  end

  @doc """
  Whether a cached usage limit is stale (observed more than 5 minutes ago).
  Used to determine if a probe should be scheduled to refresh the reading.
  """
  @spec stale?(String.t(), keyword()) :: boolean()
  def stale?(backend, opts \\ []) when is_binary(backend) do
    backend = backend_key(backend)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    state = Keyword.get(opts, :state, load(Keyword.get(opts, :path, path())))
    entry = get_in(state, ["backends", backend]) || %{}

    case Limits.parse_time(Map.get(entry, "observed_at")) do
      %DateTime{} = observed_at -> DateTime.diff(now, observed_at, :second) > @stale_threshold_seconds
      nil -> false
    end
  end

  @doc false
  @spec provider_freshness_detail([String.t()], keyword()) :: String.t()
  def provider_freshness_detail(backends, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    state = Keyword.get(opts, :state, load(Keyword.get(opts, :path, path())))

    details =
      backends
      |> Enum.map(&backend_key/1)
      |> Enum.uniq()
      |> Enum.map(fn backend ->
        entry = get_in(state, ["backends", backend]) || %{}
        observed_at = Map.get(entry, "observed_at", "unknown")

        freshness =
          cond do
            not Map.has_key?(entry, "observed_at") -> "unknown"
            stale?(backend, state: state, now: now) -> "stale"
            true -> "fresh"
          end

        next_probe = Map.get(entry, "retry_scheduled_at", "unknown")
        "#{backend}=#{freshness} observed_at=#{observed_at} next_probe=#{next_probe}"
      end)

    "backends=" <> Enum.join(details, "; ")
  end

  @doc """
  Schedule a retry probe for this backend after the retry delay (2 minutes).
  Returns updated state to be persisted.
  """
  @spec schedule_retry(String.t(), DateTime.t(), keyword()) :: :ok | {:error, term()}
  def schedule_retry(backend, now, opts \\ []) when is_binary(backend) do
    backend = backend_key(backend)
    path = Keyword.get(opts, :path, path())

    :global.trans({__MODULE__, path}, fn ->
      state = load(path)
      backends = Map.get(state, "backends", %{})
      entry = Map.get(backends, backend, %{})

      retry_at = now |> DateTime.add(@retry_delay_seconds, :second) |> DateTime.to_iso8601()
      updated_entry = Map.put(entry, "retry_scheduled_at", retry_at)

      write(path, Map.put(state, "backends", Map.put(backends, backend, updated_entry)))
    end)
  end

  @doc """
  Clear the retry schedule for a backend (called after a successful probe).
  """
  @spec clear_retry_schedule(String.t(), keyword()) :: :ok | {:error, term()}
  def clear_retry_schedule(backend, opts \\ []) when is_binary(backend) do
    backend = backend_key(backend)
    path = Keyword.get(opts, :path, path())

    :global.trans({__MODULE__, path}, fn ->
      state = load(path)
      backends = Map.get(state, "backends", %{})
      entry = Map.get(backends, backend, %{})

      updated_entry = Map.delete(entry, "retry_scheduled_at")
      write(path, Map.put(state, "backends", Map.put(backends, backend, updated_entry)))
    end)
  end

  @doc """
  Check if a retry probe is currently due (scheduled time has arrived).
  """
  @spec retry_scheduled?(String.t(), keyword()) :: boolean()
  def retry_scheduled?(backend, opts \\ []) when is_binary(backend) do
    backend = backend_key(backend)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    state = Keyword.get(opts, :state, load(Keyword.get(opts, :path, path())))
    entry = get_in(state, ["backends", backend]) || %{}

    case Limits.parse_time(Map.get(entry, "retry_scheduled_at")) do
      %DateTime{} = retry_at -> DateTime.compare(now, retry_at) != :lt
      nil -> false
    end
  end

  @doc """
  Trigger probes for any stale limits in the given list of backends.
  Non-blocking: spawns probes asynchronously in the background.
  Returns the number of probes scheduled.
  """
  @spec probe_stale_limits([String.t()], keyword()) :: non_neg_integer()
  def probe_stale_limits(backends, opts \\ []) when is_list(backends) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    path = Keyword.get(opts, :path, path())
    state = Keyword.get(opts, :state, load(path))

    stale_backends =
      backends
      |> Enum.filter(fn backend ->
        backend_key(backend) == "codex" and stale_or_unknown?(backend, state: state, now: now, path: path) and
          probe_due?(backend, state: state, now: now, path: path)
      end)

    probe_fun = Keyword.get(opts, :probe_fun, &CodexProber.probe_async/2)

    Enum.each(stale_backends, fn backend ->
      schedule_retry(backend, now, path: path)
      probe_fun.(backend, path: path, now: now)
    end)

    Enum.count(stale_backends)
  end

  defp stale_or_unknown?(backend, opts) do
    backend = backend_key(backend)
    state = Keyword.fetch!(opts, :state)
    entry = get_in(state, ["backends", backend]) || %{}
    not Map.has_key?(entry, "observed_at") or stale?(backend, opts)
  end

  defp probe_due?(backend, opts) do
    backend = backend_key(backend)
    state = Keyword.fetch!(opts, :state)
    entry = get_in(state, ["backends", backend]) || %{}

    case Limits.parse_time(Map.get(entry, "retry_scheduled_at")) do
      nil -> true
      %DateTime{} = retry_at -> DateTime.compare(Keyword.fetch!(opts, :now), retry_at) != :lt
    end
  end

  defp write(path, state) do
    File.mkdir_p(Path.dirname(path))
    tmp = path <> ".#{System.unique_integer([:positive])}.tmp"

    case File.write(tmp, Jason.encode!(state, pretty: true) <> "\n") do
      :ok -> File.rename(tmp, path)
      {:error, _reason} = error -> error
    end
  end
end
