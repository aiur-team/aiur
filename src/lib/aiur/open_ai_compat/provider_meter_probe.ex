defmodule Aiur.OpenAICompat.ProviderMeterProbe do
  @moduledoc false

  alias Aiur.{CodingAgent, ProviderMeterSnapshot}
  alias Aiur.OpenAICompat.{Concurrency, MeterWindows}
  alias Aiur.ProviderMeters.Events

  @backend :openai_compat
  @source_versions %{deepseek: 144_003, openrouter: 144_004}

  @spec probe(atom(), String.t(), keyword()) :: map()
  def probe(:kimi, _backend, _opts),
    do: outcome(:kimi, false, :session_observation_only)

  def probe(provider, backend, opts) when provider in [:deepseek, :openrouter] do
    with {:ok, config} <- config(backend),
         {:ok, env_name} <- meter_key_env(provider, config),
         {:ok, api_key} <- fetch_api_key(env_name, opts),
         request = balance_request(provider, config, api_key),
         {:ok, response} <- request(request, opts),
         :ok <- response_status(response),
         {:ok, windows} <- balance_windows(provider, Map.get(response, :body), opts) do
      publish(provider, windows, opts)
      outcome(provider, true, nil)
    else
      {:error, reason} -> outcome(provider, false, reason)
    end
  rescue
    _error -> outcome(provider, false, :probe_failed)
  catch
    _kind, _reason -> outcome(provider, false, :probe_failed)
  end

  defp publish(provider, windows, opts) do
    observed_at = Keyword.get(opts, :observed_at, DateTime.utc_now())
    source_version = Map.fetch!(@source_versions, provider)

    Events.broadcast(%ProviderMeterSnapshot{
      provider: provider,
      backend: @backend,
      provider_account_generation: nil,
      observed_at: observed_at,
      ingested_at: observed_at,
      auth_mode: :api_key,
      source: meter_source(provider),
      source_version: source_version,
      update_kind: :patch,
      freshness: :fresh,
      health: %{
        state: :healthy,
        failure: nil,
        last_observed_at: observed_at,
        last_source_version: source_version
      },
      windows: Map.new(windows, &{&1.limit_id, Map.delete(&1, :limit_id)})
    })
  end

  defp config(backend) do
    case get_in(CodingAgent.backends(), [backend, :openai_compat]) do
      %{} = config -> {:ok, config}
      _ -> {:error, :unsupported}
    end
  end

  defp meter_key_env(:deepseek, config), do: required_string(config[:api_key_env])
  defp meter_key_env(:openrouter, config), do: required_string(config[:management_api_key_env])

  defp required_string(value) when is_binary(value) and value != "", do: {:ok, value}
  defp required_string(_value), do: {:error, :missing_api_key_configuration}

  defp fetch_api_key(env_name, opts) do
    case Keyword.get(opts, :api_key_fetcher, &System.get_env/1).(env_name) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_api_key}
    end
  end

  defp balance_request(:deepseek, config, api_key) do
    %{
      method: :get,
      url: String.trim_trailing(config.base_url, "/") <> "/user/balance",
      headers: %{"authorization" => "Bearer #{api_key}"}
    }
  end

  defp balance_request(:openrouter, config, api_key) do
    %{
      method: :get,
      url: String.trim_trailing(config.base_url, "/") <> "/credits",
      headers: %{"authorization" => "Bearer #{api_key}"}
    }
  end

  defp request(request, opts) do
    Keyword.get(opts, :openai_compat_request_fun, &default_request/1).(request)
  end

  defp default_request(%{url: url, headers: headers}) do
    case Req.get(url, headers: Map.to_list(headers), receive_timeout: 30_000, retry: false) do
      {:ok, response} -> {:ok, %{status: response.status, body: response.body}}
      {:error, _reason} -> {:error, :transport}
    end
  end

  defp response_status(%{status: status}) when status in 200..299, do: :ok
  defp response_status(%{status: 401}), do: {:error, :authentication}
  defp response_status(%{status: 429}), do: {:error, :rate_limited}
  defp response_status(%{status: _status}), do: {:error, :provider_error}
  defp response_status(_response), do: {:error, :malformed}

  defp balance_windows(:deepseek, %{"balance_infos" => infos}, opts)
       when is_list(infos) do
    with %{} = usd <-
           Enum.find(infos, &(String.upcase(to_string(&1["currency"] || "")) == "USD")),
         {:ok, balance} <- non_negative_number(usd["total_balance"]) do
      observed_at = Keyword.get(opts, :observed_at, DateTime.utc_now())
      in_flight = Keyword.get(opts, :deepseek_in_flight, Concurrency.current("deepseek"))

      {:ok,
       [
         credit_window("prepaid-balance-usd", balance, :deepseek_api, observed_at),
         MeterWindows.deepseek_concurrency(in_flight, observed_at)
       ]}
    else
      _ -> {:error, :malformed}
    end
  end

  defp balance_windows(:openrouter, %{"data" => data}, opts) when is_map(data) do
    with {:ok, credits} <- non_negative_number(data["total_credits"]),
         {:ok, usage} <- non_negative_number(data["total_usage"]) do
      observed_at = Keyword.get(opts, :observed_at, DateTime.utc_now())

      {:ok,
       [
         credit_window(
           "credits-remaining",
           max(credits - usage, 0),
           :openrouter_api,
           observed_at
         )
       ]}
    else
      _ -> {:error, :malformed}
    end
  end

  defp balance_windows(_provider, _body, _opts), do: {:error, :malformed}

  defp credit_window(id, amount, source, observed_at) do
    %{
      limit_id: id,
      kind: :credit,
      name: :credits,
      credits: %{status: if(amount > 0, do: :available, else: :exhausted), amount: amount},
      remaining: amount,
      source: source,
      observed_at: observed_at,
      expires_at: DateTime.add(observed_at, 300, :second),
      coverage: :supported
    }
  end

  defp non_negative_number(value) when is_number(value) and value >= 0,
    do: {:ok, value}

  defp non_negative_number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} when number >= 0 -> {:ok, number}
      _ -> {:error, :malformed}
    end
  end

  defp non_negative_number(_value), do: {:error, :malformed}

  defp meter_source(:deepseek), do: :deepseek_api
  defp meter_source(:openrouter), do: :openrouter_api

  defp outcome(provider, observed?, reason),
    do: %{provider: provider, observed?: observed?, reason: reason}
end
