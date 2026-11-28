defmodule Aiur.Usage.Provider.OpenRouter.KeyLimits do
  @moduledoc """
  Reported limit and spend of the configured OpenRouter route key, from
  `GET <base_url>/key`.

  The provider reports `usage` (USD spent on the key), `limit` (nil when the key
  has no cap) and `limit_remaining`. A reading is cached for the poll interval,
  failures included, so a burst of usage reads makes at most one request per
  interval. A failure is a `:no_reading` with a reason, never a zero. The key is
  only ever sent in the request header.
  """

  @backend "openrouter"
  @poll_interval_ms 5 * 60_000
  @source "openrouter_key_api"

  @type reading :: map()

  @spec read(keyword()) :: reading()
  def read(opts \\ []) do
    cache_key = {__MODULE__, Keyword.get(opts, :openrouter_key_cache, :default)}
    now = Keyword.get(opts, :now_ms, System.monotonic_time(:millisecond))
    interval = Keyword.get(opts, :openrouter_key_poll_interval_ms, @poll_interval_ms)

    case :persistent_term.get(cache_key, nil) do
      {fetched_at, reading} when now - fetched_at < interval ->
        reading

      _stale_or_absent ->
        reading = fetch(opts)
        :persistent_term.put(cache_key, {now, reading})
        reading
    end
  end

  defp fetch(opts) do
    with {:ok, config} <- config(opts),
         {:ok, api_key} <- api_key(config, opts),
         {:ok, response} <- request(config, api_key, opts),
         {:ok, data} <- body(response) do
      reported(data, Keyword.get(opts, :observed_at, DateTime.utc_now()))
    else
      {:error, reason} -> no_reading(reason)
    end
  rescue
    _error -> no_reading(:probe_failed)
  catch
    _kind, _reason -> no_reading(:probe_failed)
  end

  defp config(opts) do
    backends = Keyword.get_lazy(opts, :openrouter_backends, &Aiur.CodingAgent.backends/0)

    case get_in(backends, [@backend, :openai_compat]) do
      %{base_url: url, api_key_env: env} = config when is_binary(url) and is_binary(env) and env != "" -> {:ok, config}
      _other -> {:error, :not_configured}
    end
  end

  defp api_key(config, opts) do
    case Keyword.get(opts, :api_key_fetcher, &System.get_env/1).(config.api_key_env) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, :missing_api_key}
    end
  end

  defp request(config, api_key, opts) do
    request = %{url: String.trim_trailing(config.base_url, "/") <> "/key", headers: %{"authorization" => "Bearer " <> api_key}}
    Keyword.get(opts, :openrouter_key_request_fun, &default_request/1).(request)
  end

  defp default_request(%{url: url, headers: headers}) do
    if Application.get_env(:aiur, :openrouter_key_poll?, true), do: get(url, headers), else: {:error, :polling_disabled}
  end

  defp get(url, headers) do
    case Req.get(url, headers: Map.to_list(headers), receive_timeout: 10_000, retry: false) do
      {:ok, response} -> {:ok, %{status: response.status, body: response.body}}
      {:error, _reason} -> {:error, :transport}
    end
  end

  defp body(%{status: status, body: %{"data" => %{"usage" => usage} = data}}) when status in 200..299 and is_number(usage),
    do: {:ok, data}

  defp body(%{status: status}) when status in 200..299, do: {:error, :malformed}
  defp body(%{status: status}) when status in [401, 403], do: {:error, :authentication}
  defp body(%{status: 429}), do: {:error, :rate_limited}
  defp body(%{status: _status}), do: {:error, :provider_error}
  defp body(_response), do: {:error, :malformed}

  defp reported(data, observed_at) do
    %{
      state: :reported,
      observed_at: observed_at,
      source: @source,
      currency: "USD",
      usage: data["usage"],
      limit: number(data["limit"]),
      limit_remaining: number(data["limit_remaining"]),
      is_free_tier: data["is_free_tier"] == true
    }
  end

  defp no_reading(reason), do: %{state: :no_reading, reason: reason, source: @source}

  defp number(value) when is_number(value), do: value
  defp number(_value), do: nil
end
