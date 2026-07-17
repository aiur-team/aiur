defmodule Aiur.Claude.RateLimitAdapter do
  @moduledoc false

  @source :claude_app_server
  @limit_id "rate-limit"
  @freshness_seconds 300
  @statuses ~w(allowed allowed_warning rejected unknown)
  @account_types ~w(subscription api_key unknown)
  @payload_keys ~w(jsonrpc method params)
  @params_keys ~w(turn_id thread_id rate_limit)
  @rate_limit_keys ~w(status used_percent resets_at account_type source_version)
  @version_pattern ~r/^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})[A-Za-z0-9._+() -]*$/

  @spec snapshot(map(), reference(), DateTime.t()) :: {:ok, map()} | {:error, :malformed}
  def snapshot(payload, binding, observed_at)
      when is_map(payload) and is_reference(binding) and is_struct(observed_at, DateTime) do
    with :ok <- only_keys(payload, @payload_keys),
         "rate_limit/update" <- Map.get(payload, "method"),
         %{} = params <- Map.get(payload, "params"),
         :ok <- only_keys(params, @params_keys),
         :ok <- correlation(Map.get(params, "turn_id")),
         :ok <- correlation(Map.get(params, "thread_id")),
         %{} = rate_limit <- Map.get(params, "rate_limit"),
         :ok <- only_keys(rate_limit, @rate_limit_keys),
         {:ok, standing} <- enum(Map.get(rate_limit, "status"), @statuses),
         {:ok, auth_mode} <- auth_mode(Map.get(rate_limit, "account_type")),
         {:ok, source_version} <- source_version(Map.get(rate_limit, "source_version")),
         {:ok, used_percent} <- optional_percent(Map.get(rate_limit, "used_percent")),
         {:ok, resets_at} <- optional_reset(Map.get(rate_limit, "resets_at")) do
      {:ok,
       %{
         schema_version: 1,
         # The pinned method carries the complete current state of its one
         # anonymous rate-limit control. Treating it as a full observation
         # permits honest failure recovery without inventing sparse window IDs.
         update_kind: :snapshot,
         provider: :claude,
         backend: :app_server,
         account_generation_binding: binding,
         auth_mode: auth_mode,
         plan: nil,
         observed_at: observed_at,
         source: @source,
         source_version: source_version,
         windows: [window(standing, used_percent, resets_at, observed_at)]
       }}
    else
      _ -> {:error, :malformed}
    end
  end

  def snapshot(_payload, _binding, _observed_at), do: {:error, :malformed}

  @spec failure(reference(), term(), DateTime.t()) :: map()
  def failure(binding, reason, observed_at) when is_reference(binding) and is_struct(observed_at, DateTime) do
    %{
      schema_version: 1,
      provider: :claude,
      backend: :app_server,
      account_generation_binding: binding,
      reason: failure_reason(reason),
      observed_at: observed_at
    }
  end

  defp window(standing, used_percent, resets_at, observed_at) do
    %{
      limit_id: @limit_id,
      kind: :rate_limit,
      name: :primary,
      standing: standing(standing),
      source: @source,
      observed_at: observed_at,
      expires_at: expiry(observed_at, resets_at),
      coverage: :supported
    }
    |> put_if_present(:used_percent, used_percent)
    |> put_if_present(:resets_at, resets_at)
  end

  defp expiry(observed_at, nil), do: DateTime.add(observed_at, @freshness_seconds, :second)

  defp expiry(observed_at, resets_at) do
    freshness_expiry = DateTime.add(observed_at, @freshness_seconds, :second)
    if DateTime.compare(resets_at, freshness_expiry) == :lt, do: resets_at, else: freshness_expiry
  end

  defp auth_mode(value) do
    with {:ok, value} <- enum(value, @account_types) do
      {:ok, auth_mode_atom(value)}
    end
  end

  defp standing("allowed"), do: :allowed
  defp standing("allowed_warning"), do: :allowed_warning
  defp standing("rejected"), do: :rejected
  defp standing("unknown"), do: :unknown
  defp auth_mode_atom("subscription"), do: :subscription
  defp auth_mode_atom("api_key"), do: :api_key
  defp auth_mode_atom("unknown"), do: :unknown

  defp source_version(value) when is_binary(value) and byte_size(value) in 1..96 do
    case Regex.run(@version_pattern, value, capture: :all_but_first) do
      [major, minor, patch] ->
        version = String.to_integer(major) * 1_000_000 + String.to_integer(minor) * 1_000 + String.to_integer(patch)
        if version > 0, do: {:ok, version}, else: {:error, :malformed}

      _ ->
        {:error, :malformed}
    end
  end

  defp source_version(_value), do: {:error, :malformed}

  defp optional_percent(nil), do: {:ok, nil}

  defp optional_percent(value) when is_number(value) and value >= 0 and value <= 100,
    do: {:ok, value}

  defp optional_percent(_value), do: {:error, :malformed}

  defp optional_reset(nil), do: {:ok, nil}

  defp optional_reset(value) when is_integer(value) and value >= 0 do
    case DateTime.from_unix(value) do
      {:ok, datetime} -> {:ok, datetime}
      _ -> {:error, :malformed}
    end
  end

  defp optional_reset(value) when is_float(value) and value >= 0 do
    case DateTime.from_unix(round(value * 1_000), :millisecond) do
      {:ok, datetime} -> {:ok, datetime}
      _ -> {:error, :malformed}
    end
  end

  defp optional_reset(_value), do: {:error, :malformed}

  defp correlation(value) when is_binary(value) and byte_size(value) in 1..160, do: :ok
  defp correlation(_value), do: {:error, :malformed}

  defp only_keys(map, allowed) do
    if Enum.all?(Map.keys(map), &(&1 in allowed)), do: :ok, else: {:error, :malformed}
  end

  defp enum(value, allowed), do: if(value in allowed, do: {:ok, value}, else: {:error, :malformed})
  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp failure_reason(:malformed), do: :malformed
  defp failure_reason(:timeout), do: :timeout
  defp failure_reason(:authentication), do: :authentication
  defp failure_reason(_reason), do: :transport
end
