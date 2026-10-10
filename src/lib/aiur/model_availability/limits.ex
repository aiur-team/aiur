defmodule Aiur.ModelAvailability.Limits do
  @moduledoc false

  # Pure limit/reset predicates and ledger-entry normalization; no file IO.

  @windows ~w(hourly weekly monthly)
  @unknown_reset_ttl_seconds 3_600
  # A refusal within this time of the previous one is a repeat. It is two
  # capped holds, so a refusal just after a one-hour hold still counts.
  @repeat_window_seconds 2 * @unknown_reset_ttl_seconds
  # The second refusal holds for twice this; each repeat doubles the hold.
  @backoff_base_seconds 300

  def limited?(entry, now) do
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
  def record_limit_streak(entry, existing, %{"limited" => true}, now, opts) do
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

  def record_limit_streak(entry, _existing, _normalized, _now, _opts), do: entry

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

  def normalize_limits(limits) when is_map(limits) do
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

  def normalize_limits(_), do: %{}

  def merge_entry(new_entry, existing) do
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

  def record_observation(entry, normalized, now) do
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

  def positive_observation_after_limit?(entry) do
    later_than_limit?(
      parse_time(Map.get(entry, "available_observed_at")),
      parse_time(Map.get(entry, "limited_observed_at"))
    )
  end

  defp later_than_limit?(%DateTime{}, nil), do: true

  defp later_than_limit?(%DateTime{} = available_at, %DateTime{} = limited_at),
    do: DateTime.compare(available_at, limited_at) == :gt

  defp later_than_limit?(_available_at, _limited_at), do: false

  def elapsed_real_reset?(entry, now) do
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

  def add_unknown_reset_deadlines(entry, now) do
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

  def parse_time(%DateTime{} = value), do: value

  def parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _offset} -> time
      _ -> nil
    end
  end

  def parse_time(value) when is_integer(value), do: DateTime.from_unix(value) |> unwrap_datetime()

  def parse_time(_), do: nil

  defp unwrap_datetime({:ok, datetime}), do: datetime
  defp unwrap_datetime(_), do: nil
end
