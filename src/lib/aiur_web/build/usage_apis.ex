defmodule AiurWeb.Build.UsageAPIs do
  @moduledoc false
  alias Aiur.Accounts.EnvKey
  alias Aiur.BuildOrder.SourceFreshness
  alias Aiur.Usage, as: ProviderUsage
  alias AiurWeb.Build.Usage
  alias AiurWeb.RemainingMeter
  @labels %{"core" => {"core", "Requests left"}, "graphql" => {"gql", "Points left"}}

  @doc false
  @spec configured_api_keys([{atom(), String.t()}]) :: [atom()]
  def configured_api_keys(envs) do
    for {key, env} <- envs,
        value = EnvKey.read(env),
        is_binary(value) and value != "",
        do: key
  end

  @doc false
  @spec provider_usage_snapshot(keyword()) :: map()
  def provider_usage_snapshot(opts), do: ProviderUsage.snapshot(opts)

  @spec rows(term(), map(), integer()) :: [map()]
  @spec rows(term(), map(), integer(), integer() | nil) :: [map()]
  def rows(github, elevenlabs, now, github_snapshot_observed_at \\ nil), do: [github_row(github, now, github_snapshot_observed_at) | elevenlabs_rows(elevenlabs, now)]

  @doc false
  @spec provider_rows(map(), integer()) :: [map()]
  def provider_rows(records, now) do
    records
    |> Enum.filter(fn {provider, record} ->
      fields = Map.get(record, :fields) || %{}

      (provider == :fal and fields[:state] != :unconfigured) or
        (provider == :netlify and fields[:reason] != :not_observed and fields[:reason] != "not_observed")
    end)
    |> Enum.map(fn {_provider, record} -> provider_row(record, now) end)
  end

  defp provider_row(%{provider: :fal, fields: fields} = record, now) do
    balance = fields[:balance]
    remaining = if is_number(fields[:limit]) and fields[:limit] > 0 and is_number(balance), do: Usage.percent(balance / fields[:limit] * 100)

    single_row(
      "fal.ai",
      "F",
      remaining,
      %{reset_at: fields[:reset_at], period: fields[:period], observed_at: SourceFreshness.ms(Map.get(record, :observed_at)), freshness: Map.get(record, :freshness)},
      now,
      [
        ["Balance", amount(fields[:balance], fields[:currency])],
        ["Actual balance", amount(fields[:actual], fields[:currency])],
        ["Estimated balance", amount(fields[:estimate], fields[:currency])]
      ]
    )
  end

  defp provider_row(%{provider: :netlify, fields: fields} = record, now) do
    credits = get_in(fields, [:credits]) || %{}
    remaining = credits[:estimated_remaining]
    limit = get_in(fields, [:account, :plan_credits])
    percent = if is_number(remaining) and is_number(limit) and limit > 0, do: Usage.percent(remaining / limit * 100)

    single_row("Netlify", "N", percent, %{period: "billing period", observed_at: SourceFreshness.ms(Map.get(record, :observed_at)), freshness: Map.get(record, :freshness)}, now, [
      ["Estimated balance", amount(remaining, "credits")],
      ["Actual balance", amount(credits[:anchor_balance], "credits")],
      ["Estimate", credits[:estimate] || "unknown"]
    ])
  end

  defp provider_row(record, now) do
    fields = Map.get(record, :fields) || %{}
    used = fields[:actual]
    limit = fields[:limit]
    percent = if is_number(used) and is_number(limit) and limit > 0, do: Usage.percent((limit - used) / limit * 100)

    single_row(
      Atom.to_string(Map.get(record, :provider)),
      nil,
      percent,
      %{reset_at: fields[:reset_at], period: fields[:period], observed_at: SourceFreshness.ms(Map.get(record, :observed_at)), freshness: Map.get(record, :freshness)},
      now,
      [
        ["Actual", number_text(used)],
        ["Estimate", number_text(fields[:estimate])],
        ["Status", fields[:reason] || "unknown"]
      ]
    )
  end

  defp single_row(name, mono, percent, meter, now, details) do
    observed_at = Map.get(meter, :observed_at)
    period = Map.get(meter, :period)
    age = if is_integer(observed_at), do: max(now - observed_at, 0)
    details = details ++ [["Period", period || "unknown"], ["Observed age", if(age, do: "#{div(age, 1000)}s", else: "unknown")], ["Freshness", to_string(Map.get(meter, :freshness) || :unknown)]]
    reset_at = Map.get(meter, :reset_at)
    line = %{tag: "usage", acc: [percent], reset_at: reset_at && SourceFreshness.ms(reset_at), win: period, tip: details, hold_until: nil}
    %{Usage.row(name) | mono: mono, lines: [line], observed_at: observed_at, stale: ended?(line.reset_at, now)}
  end

  defp amount(value, unit) when is_number(value), do: "#{value} #{unit || ""}" |> String.trim()
  defp amount(_, _), do: "unknown"
  defp number_text(value) when is_number(value), do: to_string(value)
  defp number_text(_), do: "unknown"

  defp github_row(input, now, snapshot_observed_at) do
    snapshot =
      case input do
        {:ok, snapshot} -> snapshot
        _ -> %{state: :unavailable, windows: %{}, backoffs: []}
      end

    lines = Enum.map(~w(core graphql), &github_line(snapshot, &1, now))
    observations = snapshot.windows |> Map.values() |> Enum.map(&SourceFreshness.ms(Map.get(&1, :observed_at))) |> Enum.reject(&is_nil/1)

    %{
      Usage.row("GitHub")
      | icon: "github",
        lines: lines,
        observed_at: Enum.max(observations, fn -> nil end),
        snapshot_observed_at: snapshot_observed_at,
        stale: Enum.any?(lines, &ended?(&1.reset_at, now))
    }
  end

  defp github_line(snapshot, resource, now) do
    {tag, label} = Map.fetch!(@labels, resource)
    window = if snapshot.state != :unknown, do: Map.get(snapshot.windows, resource)
    base = %{tag: tag, acc: [nil], reset_at: nil, win: "1h", tip: [[label, "not observed yet"]], hold_until: nil}

    case window do
      %{used_percent: percent, limit: limit, remaining: remaining} when is_number(percent) and is_number(limit) and limit > 0 and is_number(remaining) ->
        reset = SourceFreshness.ms(window.reset_at)

        %{
          base
          | acc: [Usage.percent(RemainingMeter.percent(percent))],
            reset_at: reset,
            tip: [[label, "#{commas(remaining)} of #{commas(limit)} · #{percent_text(RemainingMeter.percent(percent))}% left"]],
            hold_until: hold_until(snapshot, resource, window, now)
        }

      _ ->
        note = if snapshot.state == :unavailable, do: "GitHub budget meter unavailable", else: "not observed yet"
        %{base | tip: [[label, note]]}
    end
  end

  defp hold_until(snapshot, resource, window, now) do
    reset = SourceFreshness.ms(window.reset_at)
    floor = if window.remaining * 100 <= window.limit * 10 and future?(reset, now), do: reset
    backoff = snapshot |> Map.get(:backoffs, []) |> Enum.filter(&(&1.resource == resource)) |> Enum.map(&SourceFreshness.ms(&1.until)) |> Enum.filter(&future?(&1, now)) |> Enum.max(fn -> nil end)
    later(floor, backoff)
  end

  defp elevenlabs_rows(%{state: :unconfigured}, _now), do: []

  defp elevenlabs_rows(snapshot, now) do
    {percent, reset, details} =
      case snapshot do
        %{state: :observed, window: window} ->
          {Usage.percent(RemainingMeter.percent(window.used_percent)), SourceFreshness.ms(window.reset_at),
           [["Characters used", number_text(Map.get(window, :used))], ["Characters left", Usage.compact_number(window.remaining)], ["Quota", number_text(Map.get(window, :limit))]]}

        %{state: :failed, failure: failure} ->
          {nil, nil, [["Status", Usage.elevenlabs_failure(failure)]]}

        _ ->
          {nil, nil, [["Status", "not observed yet"]]}
      end

    observed_at = SourceFreshness.ms(Map.get(snapshot, :observed_at))
    age = if is_integer(observed_at), do: max(now - observed_at, 0)
    freshness = if snapshot.state == :observed, do: "fresh", else: "unknown"
    details = details ++ [["Period", "character quota"], ["Observed age", if(age, do: "#{div(age, 1000)}s", else: "unknown")], ["Freshness", freshness]]
    line = %{tag: "credits", acc: [percent], reset_at: reset, win: "character quota", tip: details, hold_until: nil}
    [%{Usage.row("ElevenLabs") | mono: "E", lines: [line], observed_at: observed_at, stale: ended?(reset, now)}]
  end

  defp commas(number), do: number |> round() |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")
  defp percent_text(number), do: number |> round() |> Integer.to_string()
  defp future?(at, now), do: is_integer(at) and at > now
  defp ended?(at, now), do: is_integer(at) and at < now
  defp later(nil, at), do: at
  defp later(at, nil), do: at
  defp later(a, b), do: max(a, b)
end
