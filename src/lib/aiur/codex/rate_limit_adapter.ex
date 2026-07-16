defmodule Aiur.Codex.RateLimitAdapter do
  @moduledoc false

  @source :codex_app_server
  @adapter_mapping_version 144_004
  @auth_modes [:subscription, :api_key, :unknown]
  @rate_limit_kinds [primary: "primary", secondary: "secondary"]
  @snapshot_fields ~w(limitId limitName planType primary secondary credits individualLimit rateLimitReachedType)
  @legacy_compatibility_fields ~w(limited resetAt reset_at resetsAt)
  @max_limit_sets 32
  @max_windows 128

  @spec snapshot(map(), reference(), :subscription | :api_key | :unknown, DateTime.t()) ::
          {:ok, map()} | {:error, :malformed}
  def snapshot(%{"rateLimits" => %{} = legacy} = response, binding, auth_mode, observed_at)
      when is_reference(binding) and auth_mode in @auth_modes and is_struct(observed_at, DateTime) do
    with {:ok, limit_sets} <- full_limit_sets(response, legacy),
         :ok <- full_snapshot_shape(limit_sets),
         {:ok, windows} <- snapshot_windows(limit_sets, observed_at),
         {:ok, reset_credit_window} <- reset_credit_window(response, observed_at),
         :ok <- valid_window_count(windows, reset_credit_window),
         {:ok, plan} <- plan(legacy, limit_sets, observed_at) do
      {:ok,
       update(:snapshot, binding, auth_mode, observed_at,
         windows: windows ++ List.wrap(reset_credit_window),
         plan: plan
       )}
    else
      _ -> {:error, :malformed}
    end
  end

  def snapshot(_response, _binding, _auth_mode, _observed_at), do: {:error, :malformed}

  @spec snapshot_limit_ids(map()) :: {:ok, [String.t()]} | {:error, :malformed}
  def snapshot_limit_ids(%{"rateLimits" => %{} = legacy} = response) do
    with {:ok, limit_sets} <- full_limit_sets(response, legacy),
         :ok <- full_snapshot_shape(limit_sets) do
      {:ok, Enum.map(limit_sets, &elem(&1, 0))}
    else
      _ -> {:error, :malformed}
    end
  end

  def snapshot_limit_ids(_response), do: {:error, :malformed}

  @spec patch(map(), reference(), :subscription | :api_key | :unknown, DateTime.t(), keyword()) ::
          {:ok, map()} | :ignore | {:error, :malformed}
  def patch(rate_limits, binding, auth_mode, observed_at, opts \\ [])

  def patch(%{} = rate_limits, binding, auth_mode, observed_at, opts)
      when is_reference(binding) and auth_mode in @auth_modes and is_struct(observed_at, DateTime) do
    case patch_shape(rate_limits) do
      :legacy ->
        :ignore

      :unknown ->
        {:error, :malformed}

      :structured ->
        with {:ok, limit_id} <- patch_limit_id(rate_limits, Keyword.get(opts, :single_limit_id)),
             {:ok, windows} <- windows_for(limit_id, rate_limits, observed_at),
             {:ok, plan} <- plan_for(rate_limits, observed_at) do
          if windows == [] and is_nil(plan) do
            :ignore
          else
            {:ok, update(:patch, binding, auth_mode, observed_at, windows: windows, plan: plan)}
          end
        end
    end
  end

  def patch(_rate_limits, _binding, _auth_mode, _observed_at, _opts), do: {:error, :malformed}

  @spec failure(reference(), term(), DateTime.t()) :: map()
  def failure(binding, reason, observed_at) when is_reference(binding) and is_struct(observed_at, DateTime) do
    %{
      schema_version: 1,
      provider: :codex,
      backend: :app_server,
      account_generation_binding: binding,
      reason: failure_reason(reason),
      observed_at: observed_at
    }
  end

  @spec auth_mode(String.t() | nil) :: :subscription | :api_key | :unknown
  def auth_mode(auth_mode) when auth_mode in ["chatgpt", "chatgptAuthTokens", "personalAccessToken"], do: :subscription
  def auth_mode("apikey"), do: :api_key
  def auth_mode(_auth_mode), do: :unknown

  defp full_limit_sets(%{"rateLimitsByLimitId" => %{} = by_limit_id}, _legacy)
       when map_size(by_limit_id) in 1..@max_limit_sets do
    by_limit_id
    |> Enum.reduce_while({:ok, []}, fn
      {limit_id, %{} = snapshot}, {:ok, sets} when is_binary(limit_id) ->
        with {:ok, canonical_limit_id} <- source_limit_id(limit_id), :ok <- matching_limit_id(snapshot, limit_id) do
          {:cont, {:ok, [{canonical_limit_id, snapshot} | sets]}}
        else
          _ -> {:halt, {:error, :malformed}}
        end

      _entry, _sets ->
        {:halt, {:error, :malformed}}
    end)
    |> reverse_sets()
  end

  defp full_limit_sets(%{"rateLimitsByLimitId" => %{} = buckets}, %{} = legacy) when map_size(buckets) == 0,
    do: full_limit_sets(%{}, legacy)

  defp full_limit_sets(%{"rateLimitsByLimitId" => %{}}, _legacy), do: {:error, :malformed}
  defp full_limit_sets(%{"rateLimitsByLimitId" => nil}, %{} = legacy), do: full_limit_sets(%{}, legacy)
  defp full_limit_sets(%{"rateLimitsByLimitId" => _other}, _legacy), do: {:error, :malformed}

  defp full_limit_sets(_response, %{} = legacy) do
    case Map.get(legacy, "limitId") do
      limit_id when is_binary(limit_id) ->
        case source_limit_id(limit_id) do
          {:ok, canonical_limit_id} -> {:ok, [{canonical_limit_id, legacy}]}
          :error -> {:error, :malformed}
        end

      _ ->
        {:ok, [{"default", legacy}]}
    end
  end

  # `limitId` is nullable in current app-server sparse notifications. We only
  # merge it when a prior full snapshot proved the account has one limit set;
  # otherwise a multi-bucket account would receive a fabricated identity.
  defp patch_limit_id(%{} = rate_limits, single_limit_id) do
    case Map.get(rate_limits, "limitId") do
      limit_id when is_binary(limit_id) ->
        case source_limit_id(limit_id) do
          {:ok, canonical_limit_id} -> {:ok, canonical_limit_id}
          :error -> {:error, :malformed}
        end

      nil when is_binary(single_limit_id) ->
        case canonical_limit_id(single_limit_id) do
          {:ok, canonical_limit_id} -> {:ok, canonical_limit_id}
          :error -> {:error, :malformed}
        end

      nil ->
        :ignore

      _ ->
        {:error, :malformed}
    end
  end

  defp reverse_sets({:ok, sets}), do: {:ok, Enum.reverse(sets)}
  defp reverse_sets(error), do: error

  defp matching_limit_id(snapshot, map_key) do
    case Map.get(snapshot, "limitId") do
      nil -> :ok
      ^map_key -> :ok
      _ -> :error
    end
  end

  defp valid_window_count(windows, reset_credit_window) do
    if length(windows) + if(is_nil(reset_credit_window), do: 0, else: 1) <= @max_windows,
      do: :ok,
      else: {:error, :malformed}
  end

  defp full_snapshot_shape(limit_sets) do
    Enum.reduce_while(limit_sets, :ok, fn {_limit_id, snapshot}, :ok ->
      if snapshot_shape(snapshot) == :unknown, do: {:halt, {:error, :malformed}}, else: {:cont, :ok}
    end)
  end

  defp patch_shape(snapshot) do
    case snapshot_shape(snapshot) do
      :legacy -> :legacy
      :unknown -> :unknown
      _ -> :structured
    end
  end

  defp snapshot_shape(snapshot) when map_size(snapshot) == 0, do: :structured

  defp snapshot_shape(snapshot) do
    keys = Map.keys(snapshot)

    cond do
      Enum.any?(keys, &(&1 in @snapshot_fields)) -> :structured
      Enum.any?(keys, &(&1 in @legacy_compatibility_fields)) -> :legacy
      true -> :unknown
    end
  end

  defp snapshot_windows(limit_sets, observed_at) do
    limit_sets
    |> Enum.reduce_while({:ok, []}, fn {limit_id, snapshot}, {:ok, windows} ->
      case windows_for(limit_id, snapshot, observed_at) do
        {:ok, source_windows} -> {:cont, {:ok, windows ++ source_windows}}
        _ -> {:halt, {:error, :malformed}}
      end
    end)
  end

  defp windows_for(limit_id, snapshot, observed_at) do
    with {:ok, rate_windows} <- rate_windows(limit_id, snapshot, observed_at),
         {:ok, credit_window} <- credit_window(limit_id, snapshot, observed_at),
         {:ok, spend_window} <- spend_window(limit_id, snapshot, observed_at) do
      {:ok, rate_windows ++ List.wrap(credit_window) ++ List.wrap(spend_window)}
    end
  end

  defp rate_windows(limit_id, snapshot, observed_at) do
    Enum.reduce_while(@rate_limit_kinds, {:ok, []}, fn {name, source_name}, {:ok, windows} ->
      case Map.fetch(snapshot, source_name) do
        :error ->
          {:cont, {:ok, windows}}

        {:ok, nil} ->
          {:cont, {:ok, windows}}

        {:ok, %{} = rate_window} ->
          case rate_window(limit_id, name, rate_window, observed_at) do
            {:ok, window} -> {:cont, {:ok, windows ++ [window]}}
            :error -> {:halt, {:error, :malformed}}
          end

        {:ok, _other} ->
          {:halt, {:error, :malformed}}
      end
    end)
  end

  defp rate_window(limit_id, name, %{"usedPercent" => used_percent} = source_window, observed_at)
       when is_integer(used_percent) and used_percent in 0..100 do
    with {:ok, duration_minutes} <- optional_duration(Map.get(source_window, "windowDurationMins")),
         {:ok, resets_at} <- optional_unix_timestamp(Map.get(source_window, "resetsAt")) do
      {:ok,
       %{
         limit_id: "#{limit_id}:#{name}",
         kind: :rate_limit,
         name: name,
         used_percent: used_percent,
         remaining_percent: 100 - used_percent,
         duration_minutes: duration_minutes,
         resets_at: resets_at,
         source: @source,
         observed_at: observed_at,
         coverage: :supported
       }
       |> Map.reject(fn {_key, value} -> is_nil(value) end)}
    else
      _ -> :error
    end
  end

  defp rate_window(_limit_id, _name, _source_window, _observed_at), do: :error

  defp credit_window(limit_id, snapshot, observed_at) do
    case Map.fetch(snapshot, "credits") do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, %{"hasCredits" => has_credits, "unlimited" => unlimited}} when is_boolean(has_credits) and is_boolean(unlimited) ->
        status = if unlimited, do: :unlimited, else: if(has_credits, do: :available, else: :exhausted)

        {:ok,
         %{
           limit_id: "#{limit_id}:credits",
           kind: :credit,
           name: :credits,
           credits: %{status: status},
           source: @source,
           observed_at: observed_at,
           coverage: :supported
         }}

      {:ok, _other} ->
        {:error, :malformed}
    end
  end

  defp spend_window(limit_id, snapshot, observed_at) do
    case Map.fetch(snapshot, "individualLimit") do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok,
       %{
         "used" => used,
         "limit" => limit,
         "remainingPercent" => remaining_percent,
         "resetsAt" => resets_at
       }}
      when is_binary(used) and is_binary(limit) and is_integer(remaining_percent) and remaining_percent in 0..100 and is_integer(resets_at) ->
        with {:ok, reset_at} <- optional_unix_timestamp(resets_at) do
          {:ok,
           %{
             limit_id: "#{limit_id}:spend-control",
             kind: :spend_control,
             name: :spend_control,
             remaining_percent: remaining_percent,
             resets_at: reset_at,
             spend_control: %{status: :enabled},
             source: @source,
             observed_at: observed_at,
             coverage: :supported
           }}
        else
          _ -> {:error, :malformed}
        end

      {:ok, _other} ->
        {:error, :malformed}
    end
  end

  defp reset_credit_window(response, observed_at) do
    case Map.fetch(response, "rateLimitResetCredits") do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, %{"availableCount" => count}} when is_integer(count) and count >= 0 ->
        {:ok,
         %{
           limit_id: "reset-credits",
           kind: :credit,
           name: :credits,
           credits: %{status: if(count > 0, do: :available, else: :exhausted), amount: count},
           source: @source,
           observed_at: observed_at,
           coverage: :supported
         }}

      {:ok, _other} ->
        {:error, :malformed}
    end
  end

  defp plan(legacy, limit_sets, observed_at) do
    plan_source =
      Map.get(legacy, "planType") ||
        Enum.find_value(limit_sets, fn {_limit_id, snapshot} -> Map.get(snapshot, "planType") end)

    plan_for(%{"planType" => plan_source}, observed_at)
  end

  defp plan_for(%{"planType" => nil}, _observed_at), do: {:ok, nil}
  defp plan_for(%{"planType" => plan_type}, observed_at) when is_binary(plan_type), do: {:ok, %{tier: plan_tier(plan_type), source: @source, observed_at: observed_at}}
  defp plan_for(%{} = source, _observed_at), do: if(Map.has_key?(source, "planType"), do: {:error, :malformed}, else: {:ok, nil})

  defp update(update_kind, binding, auth_mode, observed_at, opts) do
    %{
      schema_version: 1,
      update_kind: update_kind,
      provider: :codex,
      backend: :app_server,
      account_generation_binding: binding,
      auth_mode: auth_mode,
      plan: Keyword.fetch!(opts, :plan),
      observed_at: observed_at,
      source: @source,
      # The app-server response does not carry its negotiated binary version.
      # This is the version of the v2 source mapping used for reconciliation,
      # not a claim about the installed Codex binary.
      source_version: @adapter_mapping_version,
      windows: Keyword.fetch!(opts, :windows)
    }
  end

  defp optional_duration(nil), do: {:ok, nil}
  defp optional_duration(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp optional_duration(_value), do: {:error, :malformed}

  defp optional_unix_timestamp(nil), do: {:ok, nil}

  defp optional_unix_timestamp(value) when is_integer(value) and value >= 0 do
    case DateTime.from_unix(value) do
      {:ok, datetime} -> {:ok, datetime}
      _ -> {:error, :malformed}
    end
  end

  defp optional_unix_timestamp(_value), do: {:error, :malformed}

  defp plan_tier(plan_type) when plan_type in ["free"], do: :free
  defp plan_tier(plan_type) when plan_type in ["go", "plus", "pro", "prolite"], do: :pro
  defp plan_tier("team"), do: :team
  defp plan_tier(plan_type) when plan_type in ["self_serve_business_usage_based", "business"], do: :business
  defp plan_tier(plan_type) when plan_type in ["enterprise_cbp_usage_based", "enterprise"], do: :enterprise
  defp plan_tier(_plan_type), do: :unknown

  defp source_limit_id(value) when is_binary(value) and byte_size(value) in 1..1024 do
    if String.valid?(value), do: canonical_limit_id(value), else: :error
  end

  defp source_limit_id(_value), do: :error

  defp canonical_limit_id(value) when is_binary(value) and byte_size(value) in 1..80 do
    if String.match?(value, ~r/^[A-Za-z0-9._:-]+$/), do: {:ok, value}, else: opaque_limit_id(value)
  end

  defp canonical_limit_id(value) when is_binary(value), do: opaque_limit_id(value)
  defp canonical_limit_id(_value), do: :error

  defp opaque_limit_id(value) do
    {:ok, "opaque-" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))}
  end

  defp failure_reason(:account_read_failed), do: :authentication
  defp failure_reason(:response_timeout), do: :timeout
  defp failure_reason(:malformed), do: :malformed
  defp failure_reason({:invalid_rate_limits_payload, _payload}), do: :malformed
  defp failure_reason(_reason), do: :transport
end
