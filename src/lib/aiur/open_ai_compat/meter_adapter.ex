defmodule Aiur.OpenAICompat.MeterAdapter do
  @moduledoc false

  @backend :openai_compat
  @source_versions %{kimi: 144_001, deepseek: 144_002}
  @deepseek_concurrency_limit 2_500

  @spec observe(map(), map(), keyword()) :: :ok
  def observe(completion, state, opts) when is_map(completion) and is_map(state) do
    provider = state.account_generation.account_generation_provider
    observed_at = Keyword.get(opts, :meter_observed_at, DateTime.utc_now())

    case windows(provider, completion, observed_at) do
      [] ->
        :ok

      windows ->
        update = %{
          schema_version: 1,
          update_kind: :patch,
          provider: provider,
          backend: @backend,
          account_generation_binding: state.account_generation.account_generation_binding,
          auth_mode: :api_key,
          plan: nil,
          observed_at: observed_at,
          source: source(provider),
          source_version: Map.fetch!(@source_versions, provider),
          windows: windows
        }

        _ = Keyword.get(opts, :meter_ingester, &Aiur.ProviderMeters.ingest/1).(update)
        :ok
    end
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp windows(:kimi, %{headers: headers}, observed_at), do: kimi_windows(headers, observed_at)

  defp windows(:deepseek, %{local_in_flight: in_flight}, observed_at)
       when is_integer(in_flight) and in_flight >= 0 do
    [
      %{
        limit_id: "local-concurrency",
        kind: :rate_limit,
        name: :concurrency,
        used_percent: in_flight / @deepseek_concurrency_limit * 100,
        used: in_flight,
        limit: @deepseek_concurrency_limit,
        remaining: max(@deepseek_concurrency_limit - in_flight, 0),
        source: :deepseek_api,
        observed_at: observed_at,
        coverage: :supported
      }
    ]
  end

  defp windows(_provider, _completion, _observed_at), do: []

  defp kimi_windows(headers, observed_at) when is_map(headers) do
    with {:ok, limit} <- number_header(headers, "x-ratelimit-limit"),
         true <- limit > 0,
         {:ok, remaining} <- number_header(headers, "x-ratelimit-remaining") do
      remaining = remaining |> max(0) |> min(limit)

      [
        %{
          limit_id: "provider-throughput",
          kind: :rate_limit,
          name: :primary,
          used_percent: (limit - remaining) / limit * 100,
          used: limit - remaining,
          limit: limit,
          remaining: remaining,
          resets_at: reset_at(headers["x-ratelimit-reset"], observed_at),
          source: :kimi_api,
          observed_at: observed_at,
          coverage: :supported
        }
        |> Map.reject(fn {_key, value} -> is_nil(value) end)
      ]
    else
      _ -> []
    end
  end

  defp kimi_windows(_headers, _observed_at), do: []

  defp number_header(headers, key) do
    value = Map.get(headers, key)

    case Float.parse(to_string(value || "")) do
      {number, ""} when number >= 0 -> {:ok, number}
      _ -> :error
    end
  end

  defp reset_at(nil, _observed_at), do: nil

  defp reset_at(value, observed_at) do
    case Integer.parse(to_string(value)) do
      {seconds, ""} when seconds > 1_000_000_000 -> from_unix(seconds)
      {seconds, ""} when seconds >= 0 -> DateTime.add(observed_at, seconds, :second)
      _ -> nil
    end
  end

  defp from_unix(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  defp source(:kimi), do: :kimi_api
  defp source(:deepseek), do: :deepseek_api
end
