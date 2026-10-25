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

  @windows ~w(hourly weekly monthly)
  @unknown_reset_ttl_seconds 3_600
  # A refusal within this time of the previous one is a repeat. It is two
  # capped holds, so a refusal just after a one-hour hold still counts.
  @repeat_window_seconds 2 * @unknown_reset_ttl_seconds
  # The second refusal holds for twice this; each repeat doubles the hold.
  @backoff_base_seconds 300
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
      normalized = normalize_limits(limits)

      entry =
        normalized
        |> add_unknown_reset_deadlines(now)
        |> merge_entry(Map.get(backends, backend, %{}))
        |> Map.put("observed_at", DateTime.to_iso8601(now))
        |> record_limit_streak(Map.get(backends, backend, %{}), normalized, now, opts)
        |> record_observation(normalized, now)

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

    not limited?(entry, now)
  end

  @doc "Whether availability is backed by a positive observation or a real elapsed reset."
  @spec recovery_confirmed?(String.t(), keyword()) :: boolean()
  def recovery_confirmed?(backend, opts \\ []) when is_binary(backend) do
    backend = backend_key(backend)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    state = Keyword.get(opts, :state, load(Keyword.get(opts, :path, path())))
    entry = get_in(state, ["backends", backend]) || %{}

    available?(backend, Keyword.put(opts, :state, state)) and
      (positive_observation_after_limit?(entry) or elapsed_real_reset?(entry, now))
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

    case parse_time(Map.get(entry, "observed_at")) do
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

    case parse_time(Map.get(entry, "retry_scheduled_at")) do
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

    case parse_time(Map.get(entry, "retry_scheduled_at")) do
      nil -> true
      %DateTime{} = retry_at -> DateTime.compare(Keyword.fetch!(opts, :now), retry_at) != :lt
    end
  end

  defp limited?(entry, now) do
    explicit_limit? = Map.get(entry, "limited") == true
    reset_at = parse_time(Map.get(entry, "reset_at"))

    backoff_active?(entry, now) or
      (explicit_limit? and reset_active?(reset_at, entry, now)) or
      Enum.any?(@windows, &window_limited?(Map.get(entry, &1), now))
  end

  defp window_limited?(%{"used" => used, "limit" => limit} = window, now)
       when is_number(used) and is_number(limit) and limit >= 0 do
    used >= limit and future_reset?(Map.get(window, "reset_at"), now)
  end

  defp window_limited?(_, _now), do: false

  defp future_reset?(nil, _now), do: false

  defp future_reset?(value, now) do
    case parse_time(value) do
      %DateTime{} = reset_at -> DateTime.compare(reset_at, now) == :gt
      nil -> false
    end
  end

  defp reset_active?(%DateTime{} = reset_at, _entry, now), do: DateTime.compare(reset_at, now) == :gt
  defp reset_active?(nil, entry, now), do: observed_recent?(entry, now)

  defp backoff_active?(entry, now), do: future_reset?(Map.get(entry, "backoff_until"), now)

  # An explicit limit (a usage-limit refusal) that follows the previous one
  # within the repeat window extends the streak; the second and later ones set
  # an exponential hold, capped at the unknown-reset ttl. Window-only
  # observations leave the streak and the hold alone.
  defp record_limit_streak(entry, existing, %{"limited" => true}, now, opts) do
    streak = if repeat_limit?(existing, now), do: Map.get(existing, "limit_streak", 1) + 1, else: 1
    base = Keyword.get(opts, :backoff_base_seconds, @backoff_base_seconds)

    entry = Map.put(entry, "limit_streak", streak)

    if streak > 1 do
      hold = min(base * Integer.pow(2, min(streak - 1, 16)), @unknown_reset_ttl_seconds)
      Map.put(entry, "backoff_until", now |> DateTime.add(hold, :second) |> DateTime.to_iso8601())
    else
      Map.delete(entry, "backoff_until")
    end
  end

  defp record_limit_streak(entry, _existing, _normalized, _now, _opts), do: entry

  defp repeat_limit?(%{"limit_streak" => streak} = existing, now) when is_integer(streak) and streak > 0 do
    reset_disproved?(existing, now) and
      case parse_time(Map.get(existing, "limited_observed_at")) do
        %DateTime{} = previous -> DateTime.diff(now, previous, :second) < @repeat_window_seconds
        nil -> false
      end
  end

  defp repeat_limit?(_existing, _now), do: false

  # Only a refusal that arrives **at or after** the reset the previous refusal
  # printed disproves that reset, and only a disproved reset earns a backoff.
  #
  # A refusal that lands before the known reset carries no new information: it
  # is another worker meeting the same still-active limit. A fleet-wide limit
  # produces one such refusal per agent within seconds, and counting those as
  # repeats drove the streak straight to the one-hour cap and re-armed a full
  # hour from the last straggler, holding the backend past a reset the provider
  # had already told us. A provider that prints no reset is unchanged: there is
  # nothing to disprove, so every repeat still escalates.
  defp reset_disproved?(existing, now) do
    case parse_time(Map.get(existing, "reset_at")) do
      %DateTime{} = reset_at -> DateTime.compare(now, reset_at) != :lt
      nil -> true
    end
  end

  defp observed_recent?(entry, now) do
    case parse_time(Map.get(entry, "observed_at")) do
      %DateTime{} = observed_at -> DateTime.diff(now, observed_at, :second) < @unknown_reset_ttl_seconds
      nil -> false
    end
  end

  defp normalize_limits(limits) when is_map(limits) do
    limits = stringify_keys(limits)

    direct =
      Enum.reduce(@windows, %{}, fn window, acc ->
        case Map.get(limits, window) do
          %{} = value -> Map.put(acc, window, normalize_window(value))
          _ -> acc
        end
      end)

    ["primary", "secondary"]
    |> Enum.reduce(
      %{"limited" => limits["limited"], "reset_at" => limits["reset_at"] || limits["resetAt"] || limits["resetsAt"]}
      |> Map.reject(fn {_key, value} -> is_nil(value) end),
      &maybe_add_bucket(limits, &1, &2)
    )
    |> Map.merge(direct)
  end

  defp normalize_limits(_), do: %{}

  defp merge_entry(new_entry, existing) do
    existing =
      cond do
        Enum.any?(@windows, &Map.has_key?(new_entry, &1)) and not Map.has_key?(new_entry, "limited") ->
          Map.drop(existing, ["limited", "reset_at"])

        # A new limit with no reset must not inherit the reset of an older
        # limit that already passed: that would read as available at once.
        Map.get(new_entry, "limited") == true and not Map.has_key?(new_entry, "reset_at") ->
          Map.delete(existing, "reset_at")

        true ->
          existing
      end

    existing
    |> Map.merge(Map.drop(new_entry, @windows))
    |> Map.merge(Map.take(new_entry, @windows))
  end

  defp record_observation(entry, normalized, now) do
    timestamp = DateTime.to_iso8601(now)

    cond do
      limit_observation?(normalized) ->
        Map.put(entry, "limited_observed_at", timestamp)

      positive_observation?(normalized) and not limited?(entry, now) ->
        Map.put(entry, "available_observed_at", timestamp)

      true ->
        entry
    end
  end

  defp limit_observation?(entry) do
    Map.get(entry, "limited") == true or
      Enum.any?(@windows, &exhausted_window?(Map.get(entry, &1)))
  end

  defp positive_observation?(entry) do
    Map.get(entry, "limited") == false or
      Enum.any?(@windows, &available_window_observation?(Map.get(entry, &1)))
  end

  defp exhausted_window?(%{"used" => used, "limit" => limit})
       when is_number(used) and is_number(limit),
       do: used >= limit

  defp exhausted_window?(_window), do: false

  defp available_window_observation?(%{"used" => used, "limit" => limit})
       when is_number(used) and is_number(limit),
       do: used < limit

  defp available_window_observation?(_window), do: false

  defp positive_observation_after_limit?(entry) do
    later_than_limit?(
      parse_time(Map.get(entry, "available_observed_at")),
      parse_time(Map.get(entry, "limited_observed_at"))
    )
  end

  defp later_than_limit?(%DateTime{}, nil), do: true

  defp later_than_limit?(%DateTime{} = available_at, %DateTime{} = limited_at),
    do: DateTime.compare(available_at, limited_at) == :gt

  defp later_than_limit?(_available_at, _limited_at), do: false

  defp elapsed_real_reset?(entry, now) do
    explicit_reset_elapsed?(entry, now) or
      Enum.any?(@windows, &window_real_reset_elapsed?(Map.get(entry, &1), entry, now))
  end

  defp explicit_reset_elapsed?(%{"limited" => true} = entry, now) do
    reset_elapsed?(Map.get(entry, "reset_at"), now)
  end

  defp explicit_reset_elapsed?(_entry, _now), do: false

  defp window_real_reset_elapsed?(%{"used" => used, "limit" => limit} = window, entry, now)
       when is_number(used) and is_number(limit) and used >= limit do
    not estimated_reset?(window, entry) and reset_elapsed?(Map.get(window, "reset_at"), now)
  end

  defp window_real_reset_elapsed?(_window, _entry, _now), do: false

  defp estimated_reset?(%{"reset_estimated" => true}, _entry), do: true
  defp estimated_reset?(%{"reset_estimated" => false}, _entry), do: false

  # Older ledgers cannot distinguish provider resets from the one-hour guess.
  # Stay conservative until a fresh observation records explicit provenance.
  defp estimated_reset?(_window, _entry), do: true

  defp reset_elapsed?(value, now) do
    case parse_time(value) do
      %DateTime{} = reset_at -> DateTime.compare(reset_at, now) != :gt
      nil -> false
    end
  end

  defp add_unknown_reset_deadlines(entry, now) do
    Enum.reduce(@windows, entry, fn window, acc ->
      case Map.get(acc, window) do
        %{"used" => used, "limit" => limit} = bucket when is_number(used) and is_number(limit) and used >= limit ->
          estimated =
            bucket
            |> Map.put_new(
              "reset_at",
              DateTime.add(now, @unknown_reset_ttl_seconds, :second) |> DateTime.to_iso8601()
            )
            |> Map.put_new("reset_estimated", not Map.has_key?(bucket, "reset_at"))

          Map.put(acc, window, estimated)

        _ ->
          acc
      end
    end)
  end

  defp maybe_add_bucket(limits, bucket, acc) do
    with %{} = value <- Map.get(limits, bucket),
         window when is_binary(window) <- window_name(value) do
      Map.put_new(acc, window, normalize_window(value))
    else
      _ -> acc
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), if(is_map(value), do: stringify_keys(value), else: value)} end)
  end

  defp normalize_window(window) do
    percent = number(window["used_percent"]) || number(window["usedPercent"])
    used = percent || number(window["used"])
    limit = if(is_number(percent), do: 100, else: number(window["limit"]))

    %{"used" => used, "limit" => limit, "reset_at" => window["reset_at"] || window["resetAt"] || window["resetsAt"]}
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp window_name(window) do
    case number(window["window_minutes"] || window["windowDurationMins"]) do
      minutes when is_number(minutes) and minutes < 10_080 -> "hourly"
      minutes when is_number(minutes) and minutes <= 10_080 -> "weekly"
      minutes when is_number(minutes) -> "monthly"
      _ -> nil
    end
  end

  defp number(value) when is_number(value), do: value

  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp number(_), do: nil

  defp parse_time(%DateTime{} = value), do: value

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _offset} -> time
      _ -> nil
    end
  end

  defp parse_time(value) when is_integer(value), do: DateTime.from_unix(value) |> unwrap_datetime()

  defp parse_time(_), do: nil

  defp unwrap_datetime({:ok, datetime}), do: datetime
  defp unwrap_datetime(_), do: nil

  defp write(path, state) do
    File.mkdir_p(Path.dirname(path))
    tmp = path <> ".#{System.unique_integer([:positive])}.tmp"

    case File.write(tmp, Jason.encode!(state, pretty: true) <> "\n") do
      :ok -> File.rename(tmp, path)
      {:error, _reason} = error -> error
    end
  end
end
