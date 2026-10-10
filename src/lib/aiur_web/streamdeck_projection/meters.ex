defmodule AiurWeb.StreamdeckProjection.Meters do
  @moduledoc """
  Provider meter normalisation for `AiurWeb.StreamdeckProjection`: maps a
  provider's backend-native limit windows onto the deck's two fixed
  Session/Weekly slots, attaches the durable last-known reading for a provider
  not observed this boot, and derives each reading's freshness.
  """

  alias Aiur.ModelAvailability

  @default_usage_interval_seconds 300
  @stale_after_intervals 2
  @session_window_tokens ~w(session primary five_hour hourly)
  @weekly_window_tokens ~w(weekly secondary seven_day)

  # The provider projection intentionally preserves backend-native limit IDs
  # (for example, `five_hour`/`seven_day` and `primary`/`secondary`). The
  # Stream Deck has two fixed physical meter positions, so it maps two distinct
  # rate-limit observations into its semantic Session/Weekly slots here. It
  # never invents a second value: a provider with one usable reading has one
  # populated slot and an explicitly unobserved other slot.
  @spec normalize_provider_meter(atom(), term(), DateTime.t()) :: map()
  def normalize_provider_meter(provider, meter, now) when is_map(meter) do
    observed_at = meter |> field(:observed_at) |> datetime()
    freshness = meter_freshness(meter, observed_at, now)
    state = meter_state(meter, observed_at)

    normalized =
      %{
        provider: provider,
        summary_label: field(meter, :summary_label),
        ingested_at: field(meter, :ingested_at),
        state: state,
        observed_at: observed_at,
        age_seconds: age_seconds(observed_at, now),
        auth_mode: field(meter, :auth_mode),
        plan: field(meter, :plan),
        freshness: freshness,
        health: field(meter, :health),
        windows: normalized_windows(provider, meter, observed_at, now, freshness)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    if state == :unknown, do: maybe_attach_durable(normalized, provider, now), else: normalized
  end

  def normalize_provider_meter(provider, _meter, now) do
    %{provider: provider, state: :unknown, freshness: :unknown, windows: %{}}
    |> maybe_attach_durable(provider, now)
  end

  # A provider that has never been observed this boot reads `:unknown` on the
  # deck, exactly like the dashboard's cards do before `put_durable_observation`
  # attaches the last-known standing from the durable dispatch-limits ledger
  # (`Aiur.ModelAvailability`, `model-usage.json`). The deck had no equivalent,
  # so a provider the dashboard read as, say, 99% used rendered as a permanent
  # "Awaiting data" on the strip — the two surfaces disagreeing about the same
  # account (#2185). Attach the same durable record here: the value is a real
  # last-known used% (marked stale, never live), and a later real observation
  # replaces it because this branch only runs for an unobserved meter.
  defp maybe_attach_durable(meter, provider, now) do
    case durable_window(provider, now) do
      %{} = window ->
        meter
        |> Map.merge(%{
          state: :observed,
          observed_at: window.observed_at,
          age_seconds: window.age_seconds,
          freshness: :stale,
          health: %{state: :stale, failure: nil},
          windows: %{"session" => window}
        })

      nil ->
        meter
    end
  end

  # The ledger's governing bucket becomes the deck's session slot (the primary
  # one both the emulator and the sidecar render). It carries no reliable reset
  # instant and is stale by construction, mirroring the dashboard's durable meta
  # line ("99% used · as of HH:MM UTC (stale)").
  defp durable_window(provider, now) do
    case durable_observation(provider) do
      %{percent: percent, observed_at: %DateTime{} = observed_at} when is_number(percent) ->
        %{
          used_percent: percent,
          observed_at: observed_at,
          age_seconds: age_seconds(observed_at, now),
          freshness: :stale
        }

      _ ->
        nil
    end
  end

  defp durable_observation(provider) do
    with %{"backends" => backends} <- ModelAvailability.load(),
         %{} = entry when map_size(entry) > 0 <- Map.get(backends, Atom.to_string(provider)),
         %{percent: percent} <- durable_percent_entry(entry) do
      %{percent: percent, observed_at: durable_observed_at(Map.get(entry, "observed_at"))}
    else
      _ -> nil
    end
  end

  defp durable_percent_entry(entry) do
    entry
    |> Map.take(~w(hourly weekly monthly))
    |> Enum.map(fn {_window, %{"used" => used, "limit" => limit}} when is_number(used) and is_number(limit) and limit > 0 ->
      %{percent: min(round(used / limit * 100), 100)}
    end)
    |> Enum.max_by(& &1.percent, fn -> nil end)
  end

  defp durable_observed_at(%DateTime{} = value), do: value

  defp durable_observed_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp durable_observed_at(_value), do: nil

  defp meter_state(meter, _observed_at) do
    case field(meter, :state) do
      state when state in [:observed, "observed"] -> :observed
      _ -> :unknown
    end
  end

  defp normalized_windows(provider, meter, provider_observed_at, now, provider_freshness) do
    meter
    |> field(:windows)
    |> meter_windows(provider)
    |> semantic_windows()
    |> Map.new(fn {slot, {_limit_id, window}} ->
      {slot, normalize_window(window, provider_observed_at, now, provider_freshness)}
    end)
  end

  # The dashboard shows prepaid credit windows for every provider except Codex,
  # whose credit facts are account capabilities rather than a dollar balance.
  # Keep the same distinction here so both surfaces describe the same account
  # standing. A credit window is governing, so `semantic_windows/1` gives it
  # the primary Session position on the two-slot deck.
  defp meter_windows(windows, provider) when is_map(windows) do
    windows
    |> Enum.filter(&eligible_window?(&1, provider))
    |> Enum.sort_by(fn {limit_id, window} -> {window_duration(window), to_string(limit_id)} end)
  end

  defp meter_windows(_windows, _provider), do: []

  defp eligible_window?({limit_id, window}, provider) when is_map(window) do
    if to_string(field(window, :limit_id) || limit_id) == "local-concurrency" do
      false
    else
      case field(window, :kind) do
        kind when kind in [:rate_limit, "rate_limit"] -> true
        kind when kind in [:credit, "credit"] -> provider != :codex
        _kind -> false
      end
    end
  end

  defp eligible_window?(_entry, _provider), do: false

  defp semantic_windows([]), do: []

  defp semantic_windows(windows) do
    session = Enum.find(windows, &credit_window?/1) || Enum.find(windows, &window_matches?(&1, @session_window_tokens))
    weekly = windows |> List.delete(session) |> Enum.find(&window_matches?(&1, @weekly_window_tokens))
    remaining = windows |> unclassified_windows() |> List.delete(session) |> List.delete(weekly)

    session = session || fallback_window(remaining, :shortest)
    weekly = weekly || remaining |> List.delete(session) |> fallback_window(:longest)

    [{"session", session}, {"weekly", weekly}]
    |> Enum.reject(fn {_slot, window} -> is_nil(window) end)
  end

  defp credit_window?({_limit_id, window}), do: field(window, :kind) in [:credit, "credit"]

  defp unclassified_windows(windows) do
    Enum.reject(windows, fn window ->
      credit_window?(window) or window_matches?(window, @session_window_tokens) or window_matches?(window, @weekly_window_tokens)
    end)
  end

  defp window_matches?({limit_id, _window}, tokens) do
    limit_id
    |> to_string()
    |> String.downcase()
    |> then(&Enum.any?(tokens, fn token -> String.contains?(&1, token) end))
  end

  defp fallback_window([], _fallback), do: nil
  defp fallback_window(windows, :shortest), do: Enum.min_by(windows, fn {_limit_id, window} -> window_duration(window) end)
  defp fallback_window(windows, :longest), do: Enum.max_by(windows, fn {_limit_id, window} -> window_duration(window) end)

  defp window_duration(window) do
    case field(window, :duration_minutes) do
      minutes when is_integer(minutes) and minutes >= 0 -> minutes
      _ -> 0
    end
  end

  defp normalize_window(window, provider_observed_at, now, provider_freshness) do
    observed_at = window |> field(:observed_at) |> datetime() || provider_observed_at

    %{
      used_percent: field(window, :used_percent),
      remaining: field(window, :remaining),
      resets_at: window |> field(:resets_at) |> datetime(),
      observed_at: observed_at,
      age_seconds: age_seconds(observed_at, now),
      freshness: window_freshness(window, observed_at, now, provider_freshness)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp meter_freshness(meter, observed_at, now) do
    if stale?(observed_at, now) or field(meter, :freshness) in [:stale, "stale"] or field(field(meter, :health) || %{}, :state) in [:stale, "stale"] do
      :stale
    else
      case field(meter, :freshness) do
        freshness when freshness in [:fresh, "fresh"] -> :fresh
        freshness when freshness in [:partial, "partial"] -> :partial
        _ -> :unknown
      end
    end
  end

  defp window_freshness(window, observed_at, now, provider_freshness) do
    if provider_freshness == :stale or stale?(observed_at, now) or field(window, :freshness) in [:stale, "stale"] do
      :stale
    else
      case field(window, :freshness) do
        freshness when freshness in [:fresh, "fresh"] -> :fresh
        freshness when freshness in [:partial, "partial"] -> :partial
        _ -> :unknown
      end
    end
  end

  defp stale?(nil, _now), do: false
  defp stale?(observed_at, now), do: age_seconds(observed_at, now) > usage_interval_seconds() * @stale_after_intervals

  defp usage_interval_seconds do
    case Aiur.Config.settings() do
      {:ok, %{polling: %{usage_interval_seconds: seconds}}} when is_integer(seconds) and seconds > 0 -> seconds
      _ -> @default_usage_interval_seconds
    end
  end

  @spec age_seconds(DateTime.t() | nil) :: non_neg_integer() | nil
  def age_seconds(nil), do: nil
  def age_seconds(observed_at), do: age_seconds(observed_at, DateTime.utc_now())

  @spec age_seconds(DateTime.t() | nil, DateTime.t()) :: non_neg_integer() | nil
  def age_seconds(nil, _now), do: nil
  def age_seconds(observed_at, now), do: DateTime.diff(now, observed_at) |> max(0)

  defp datetime(%DateTime{} = value), do: value

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp datetime(_value), do: nil

  @spec field(map(), atom()) :: term()
  def field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
