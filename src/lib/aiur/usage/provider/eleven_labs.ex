defmodule Aiur.Usage.Provider.ElevenLabs do
  @moduledoc "Read-only ElevenLabs character quota from the account subscription API."
  alias Aiur.Config
  alias Aiur.Usage.ProviderSupport

  defstruct [:provider, :observed_at, :age_ms, :freshness, :source, fields: %{}]

  @endpoint "https://api.elevenlabs.io/v1/user/subscription"

  @spec read(keyword()) :: struct()
  def read(opts) do
    result =
      Keyword.get_lazy(opts, :elevenlabs_usage, fn ->
        cached_fetch(opts)
      end)

    snapshot(result, Keyword.get(opts, :now, DateTime.utc_now()))
  end

  defp cached_fetch(opts) do
    if Keyword.has_key?(opts, :elevenlabs_request_fun) or Keyword.has_key?(opts, :elevenlabs_api_key) do
      fetch(opts)
    else
      key = {__MODULE__, Keyword.get(opts, :elevenlabs_cache, :default)}
      now = Keyword.get(opts, :now_ms, System.monotonic_time(:millisecond))

      case :persistent_term.get(key, nil) do
        {at, result} when now - at < 60_000 ->
          result

        _ ->
          result = fetch(opts)
          :persistent_term.put(key, {now, result})
          result
      end
    end
  end

  defp fetch(opts) do
    with key when is_binary(key) and key != "" <- Keyword.get_lazy(opts, :elevenlabs_api_key, &Config.elevenlabs_api_key/0),
         {:ok, response} <- Keyword.get(opts, :elevenlabs_request_fun, &default_request/1).(key),
         {:ok, window} <- parse(response) do
      {:ok, Map.put(window, :observed_at, Keyword.get(opts, :now, DateTime.utc_now()))}
    else
      nil -> {:error, :unconfigured}
      "" -> {:error, :unconfigured}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp default_request(key) do
    case Req.get(@endpoint, headers: [{"xi-api-key", key}], receive_timeout: 15_000, retry: false) do
      {:ok, response} -> {:ok, %{status: response.status, body: response.body}}
      {:error, _} -> {:error, :transport}
    end
  end

  defp parse(%{status: status, body: body}) when status in 200..299 and is_map(body) do
    with used when is_integer(used) and used >= 0 <- body["character_count"],
         limit when is_integer(limit) and limit >= 0 <- body["character_limit"] do
      remaining = max(limit - used, 0)

      {:ok,
       %{
         actual: used,
         estimate: nil,
         limit: limit,
         remaining: remaining,
         used_percent: if(limit > 0, do: min(used / limit * 100, 100.0) |> Float.round(1)),
         reset_at: unix_datetime(body["next_character_count_reset_unix"]),
         period: "character quota",
         unit: "characters",
         tier: body["tier"]
       }}
    else
      _ -> {:error, :malformed}
    end
  end

  defp parse(%{status: status}) when status in [401, 403], do: {:error, :authentication}
  defp parse(%{status: status}) when status in 200..299, do: {:error, :malformed}
  defp parse(_), do: {:error, :unavailable}

  defp unix_datetime(value) when is_integer(value) do
    case DateTime.from_unix(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp unix_datetime(_), do: nil

  defp snapshot({:ok, fields}, now) do
    observed = fields[:observed_at] || now

    ProviderSupport.record(__MODULE__, :elevenlabs, observed, :fresh, fields, "elevenlabs.subscription")
    |> Map.put(:age_ms, age_ms(observed, now))
  end

  defp snapshot({:error, :unconfigured}, _now),
    do: ProviderSupport.record(__MODULE__, :elevenlabs, nil, :unknown, %{state: :unconfigured, actual: nil, estimate: nil, reset_at: nil}, "elevenlabs.subscription")

  defp snapshot({:error, reason}, _now),
    do: ProviderSupport.record(__MODULE__, :elevenlabs, nil, :unknown, %{state: :unavailable, reason: reason, actual: nil, estimate: nil, reset_at: nil}, "elevenlabs.subscription")

  defp snapshot(_, _now), do: snapshot({:error, :unavailable}, nil)

  defp age_ms(%DateTime{} = observed, %DateTime{} = now), do: max(DateTime.diff(now, observed, :millisecond), 0)
  defp age_ms(_, _), do: nil
end
