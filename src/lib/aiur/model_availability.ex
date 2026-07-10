defmodule Aiur.ModelAvailability do
  @moduledoc """
  Durable observations used by the opt-in model rate-limit fallback.

  The ledger is deliberately a plain JSON file beside the active workflow
  configuration (`model-usage.json`). It is both restart-safe and easy for an
  operator to inspect without querying a running node. Providers may report a
  subset of the hourly, weekly, and monthly windows; unknown windows never
  make a backend unavailable.
  """

  alias Aiur.Workflow

  @windows ~w(hourly weekly monthly)
  @unknown_reset_ttl_seconds 3_600

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
    path = Keyword.get(opts, :path, path())
    now = Keyword.get(opts, :now, DateTime.utc_now())

    :global.trans({__MODULE__, path}, fn ->
      state = load(path)
      backends = Map.get(state, "backends", %{})

      entry =
        limits
        |> normalize_limits()
        |> add_unknown_reset_deadlines(now)
        |> merge_entry(Map.get(backends, backend, %{}))
        |> Map.put("observed_at", DateTime.to_iso8601(now))

      write(path, Map.put(state, "backends", Map.put(backends, backend, entry)))
    end)
  end

  @spec mark_limited(String.t(), String.t() | nil, keyword()) :: :ok | {:error, term()}
  def mark_limited(backend, reset_at \\ nil, opts \\ []) when is_binary(backend) do
    observe(backend, %{"limited" => true, "reset_at" => reset_at}, opts)
  end

  @spec available?(String.t(), keyword()) :: boolean()
  def available?(backend, opts \\ []) when is_binary(backend) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    entry = Keyword.get(opts, :state, load(Keyword.get(opts, :path, path()))) |> get_in(["backends", backend]) || %{}

    not limited?(entry, now)
  end

  @spec first_available([String.t()], keyword()) :: String.t() | nil
  def first_available(backends, opts \\ []) when is_list(backends) do
    state = Keyword.get(opts, :state, load(Keyword.get(opts, :path, path())))
    Enum.find(backends, &available?(&1, Keyword.put(opts, :state, state)))
  end

  defp limited?(entry, now) do
    explicit_limit? = Map.get(entry, "limited") == true
    reset_at = parse_time(Map.get(entry, "reset_at"))

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
    existing
    |> Map.merge(Map.drop(new_entry, @windows))
    |> Map.merge(Map.take(new_entry, @windows))
  end

  defp add_unknown_reset_deadlines(entry, now) do
    Enum.reduce(@windows, entry, fn window, acc ->
      case Map.get(acc, window) do
        %{"used" => used, "limit" => limit} = bucket when is_number(used) and is_number(limit) and used >= limit ->
          Map.put(acc, window, Map.put_new(bucket, "reset_at", DateTime.add(now, @unknown_reset_ttl_seconds, :second) |> DateTime.to_iso8601()))

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
      minutes when is_number(minutes) and minutes <= 60 -> "hourly"
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
