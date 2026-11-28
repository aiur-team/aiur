defmodule Aiur.Usage.Provider.Fal do
  @moduledoc "Read-only fal.ai billing balance meter."
  alias Aiur.Accounts.EnvKey
  alias Aiur.Usage.ProviderSupport

  defstruct [:provider, :observed_at, :age_ms, :freshness, :source, fields: %{}]

  @endpoint "https://api.fal.ai/v1/account/billing?expand=credits"

  @spec read(keyword()) :: struct()
  def read(opts) do
    result = Keyword.get_lazy(opts, :fal_usage, fn -> cached_fetch(opts) end)
    snapshot(result, Keyword.get(opts, :now, DateTime.utc_now()))
  end

  defp cached_fetch(opts) do
    if Keyword.has_key?(opts, :fal_request_fun) or Keyword.has_key?(opts, :fal_api_key) do
      fetch(opts)
    else
      key = {__MODULE__, Keyword.get(opts, :fal_cache, :default)}
      now = Keyword.get(opts, :now_ms, System.monotonic_time(:millisecond))

      case :persistent_term.get(key, nil) do
        {at, result} when now - at < 300_000 ->
          result

        _ ->
          result = fetch(opts)
          :persistent_term.put(key, {now, result})
          result
      end
    end
  end

  defp fetch(opts) do
    key = Keyword.get_lazy(opts, :fal_api_key, fn -> EnvKey.read("FAL_KEY") end)

    with key when is_binary(key) and key != "" <- key,
         {:ok, response} <- Keyword.get(opts, :fal_request_fun, &default_request/1).(key),
         {:ok, fields} <- parse(response) do
      {:ok, Map.put(fields, :observed_at, Keyword.get(opts, :now, DateTime.utc_now()))}
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
    case Req.get(@endpoint, headers: [{"Authorization", "Key " <> key}], receive_timeout: 15_000, retry: false) do
      {:ok, response} -> {:ok, %{status: response.status, body: response.body}}
      {:error, _} -> {:error, :transport}
    end
  end

  defp parse(%{status: status, body: body}) when status in 200..299 and is_map(body) do
    data = body["data"] || body
    credits = data["credits"] || data
    balance = first_number(credits, ["current_balance", "balance", "remaining", "remaining_credits"])
    spent = first_number(data, ["spent", "usage", "total_usage"])
    limit = first_number(credits, ["limit", "purchased", "credit_limit"])

    cond do
      is_number(balance) ->
        {:ok,
         %{
           actual: balance,
           estimate: nil,
           spend: spent,
           balance: balance,
           limit: limit,
           remaining: balance,
           currency: credits["currency"] || "USD",
           reset_at: date(body["reset_at"]),
           period: "current balance"
         }}

      is_number(spent) ->
        {:ok, %{actual: spent, estimate: nil, balance: nil, limit: limit, remaining: nil, reset_at: date(body["reset_at"]), unit: "USD"}}

      true ->
        {:error, :malformed}
    end
  end

  defp parse(%{status: 401}), do: {:error, :authentication}
  defp parse(%{status: 403}), do: {:error, :billing_permission_required}
  defp parse(%{status: 200}), do: {:error, :malformed}
  defp parse(_), do: {:error, :unavailable}

  defp first_number(body, keys), do: Enum.find_value(keys, fn key -> number(body[key]) end)
  defp number(value) when is_number(value), do: value
  defp number(_), do: nil
  defp date(%DateTime{} = value), do: value

  defp date(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> datetime
      _ -> nil
    end
  end

  defp date(_), do: nil

  defp snapshot({:ok, fields}, now) do
    observed = fields[:observed_at] || now

    ProviderSupport.record(__MODULE__, :fal, observed, :fresh, fields, "fal.usage")
    |> Map.put(:age_ms, age_ms(observed, now))
  end

  defp snapshot({:error, :unconfigured}, _now),
    do: ProviderSupport.record(__MODULE__, :fal, nil, :unknown, %{state: :unconfigured, actual: nil, estimate: nil, balance: nil, reset_at: nil}, "fal.usage")

  defp snapshot({:error, reason}, _now),
    do: ProviderSupport.record(__MODULE__, :fal, nil, :unknown, %{state: :unavailable, reason: reason, actual: nil, estimate: nil, balance: nil, reset_at: nil}, "fal.usage")

  defp snapshot(_, _now), do: snapshot({:error, :unavailable}, nil)

  defp age_ms(%DateTime{} = observed, %DateTime{} = now), do: max(DateTime.diff(now, observed, :millisecond), 0)
  defp age_ms(_, _), do: nil
end
