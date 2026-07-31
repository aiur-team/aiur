defmodule Aiur.ProviderMeters.Input do
  @moduledoc false

  # Registry-derived at compile time so a new metered backend needs no edit here.
  @providers Aiur.CodingAgent.provider_families()
  @backends [:app_server]
  @auth_modes [:subscription, :api_key, :unknown]
  # Per-provider app-server source atoms (`:codex_app_server`, …) derived from
  # the same registry providers, plus the provider-independent sources.
  @sources [:provider, :adapter, :synthetic] ++
             Enum.map(Aiur.CodingAgent.provider_families(), &:"#{&1}_app_server")
  @window_kinds [:rate_limit, :credit, :spend_control]
  @window_names %{
    primary: "Primary",
    secondary: "Secondary",
    credits: "Credits",
    spend_control: "Spend control",
    custom: "Provider limit"
  }
  @coverages [:supported, :unsupported, :empty_supported]
  @failure_reasons [:authentication, :malformed, :timeout, :transport]
  @plan_tiers [:free, :pro, :team, :business, :enterprise, :unknown]
  @max_numeric 1_000_000_000_000
  @max_source_version 1_000_000_000

  @update_keys [
    :schema_version,
    :update_kind,
    :provider,
    :backend,
    :account_generation_binding,
    :auth_mode,
    :plan,
    :observed_at,
    :source,
    :source_version,
    :windows,
    :limit_id
  ]
  @window_keys [
    :limit_id,
    :kind,
    :name,
    :standing,
    :used_percent,
    :remaining_percent,
    :used,
    :limit,
    :remaining,
    :duration_minutes,
    :resets_at,
    :credits,
    :spend_control,
    :source,
    :observed_at,
    :expires_at,
    :coverage
  ]
  @plan_keys [:tier, :source, :observed_at, :expires_at]
  @credit_keys [:status, :amount]
  @spend_control_keys [:status, :limit]
  @failure_keys [
    :schema_version,
    :provider,
    :backend,
    :account_generation_binding,
    :reason,
    :observed_at
  ]

  @spec normalize(map()) :: {:ok, map()} | {:error, :invalid_provider_meter_update}
  def normalize(input) when is_map(input) do
    with :ok <- only_keys?(input, @update_keys),
         {:ok, update_kind} <- enum(Map.get(input, :update_kind), [:snapshot, :patch, :tombstone]),
         :ok <- equal?(Map.get(input, :schema_version), 1),
         {:ok, provider} <- enum(Map.get(input, :provider), @providers),
         {:ok, backend} <- enum(Map.get(input, :backend), @backends),
         {:ok, binding} <- generation_binding(Map.get(input, :account_generation_binding)),
         {:ok, observed_at} <- datetime(Map.get(input, :observed_at)),
         {:ok, source} <- enum(Map.get(input, :source), @sources),
         {:ok, source_version} <- positive_integer(Map.get(input, :source_version)),
         {:ok, auth_mode} <- optional_enum(Map.get(input, :auth_mode), @auth_modes),
         {:ok, plan} <- optional_plan(Map.get(input, :plan)),
         {:ok, windows, limit_id} <- normalize_payload(update_kind, input) do
      {:ok,
       %{
         schema_version: 1,
         update_kind: update_kind,
         provider: provider,
         backend: backend,
         account_generation_binding: binding,
         auth_mode: auth_mode,
         plan: annotate_plan(plan, source_version),
         observed_at: observed_at,
         source: source,
         source_version: source_version,
         windows: annotate_windows(windows, source_version),
         limit_id: limit_id
       }}
    else
      _ -> {:error, :invalid_provider_meter_update}
    end
  end

  def normalize(_input), do: {:error, :invalid_provider_meter_update}

  @spec normalize_failure(map()) :: {:ok, map()} | {:error, :invalid_provider_meter_failure}
  def normalize_failure(input) when is_map(input) do
    with :ok <- only_keys?(input, @failure_keys),
         :ok <- equal?(Map.get(input, :schema_version), 1),
         {:ok, provider} <- enum(Map.get(input, :provider), @providers),
         {:ok, backend} <- enum(Map.get(input, :backend), @backends),
         {:ok, binding} <- generation_binding(Map.get(input, :account_generation_binding)),
         {:ok, reason} <- enum(Map.get(input, :reason), @failure_reasons),
         {:ok, observed_at} <- datetime(Map.get(input, :observed_at)) do
      {:ok,
       %{
         provider: provider,
         backend: backend,
         account_generation_binding: binding,
         reason: reason,
         observed_at: observed_at
       }}
    else
      _ -> {:error, :invalid_provider_meter_failure}
    end
  end

  def normalize_failure(_input), do: {:error, :invalid_provider_meter_failure}

  defp normalize_payload(:tombstone, input) do
    with true <- not Map.has_key?(input, :windows),
         {:ok, limit_id} <- limit_id(Map.get(input, :limit_id)) do
      {:ok, %{}, limit_id}
    else
      _ -> {:error, :invalid_tombstone}
    end
  end

  defp normalize_payload(kind, input) when kind in [:snapshot, :patch] do
    with true <- not Map.has_key?(input, :limit_id),
         {:ok, windows} <- windows(Map.get(input, :windows)),
         true <- kind == :patch or not is_nil(Map.get(input, :auth_mode)) do
      {:ok, windows, nil}
    else
      _ -> {:error, :invalid_windows}
    end
  end

  defp windows(values) when is_list(values) and length(values) <= 128 do
    values
    |> Enum.reduce_while({:ok, %{}}, fn value, {:ok, windows} ->
      with {:ok, window} <- window(value),
           false <- Map.has_key?(windows, window.limit_id) do
        {:cont, {:ok, Map.put(windows, window.limit_id, Map.delete(window, :limit_id))}}
      else
        _ -> {:halt, {:error, :invalid_window}}
      end
    end)
  end

  defp windows(_values), do: {:error, :invalid_windows}

  defp window(value) when is_map(value) do
    with :ok <- only_keys?(value, @window_keys),
         {:ok, limit_id} <- limit_id(Map.get(value, :limit_id)),
         {:ok, kind} <- enum(Map.get(value, :kind), @window_kinds),
         {:ok, name} <- human_name(Map.get(value, :name)),
         {:ok, standing} <- optional_enum(Map.get(value, :standing), [:allowed, :allowed_warning, :rejected, :unknown]),
         {:ok, source} <- enum(Map.get(value, :source), @sources),
         {:ok, observed_at} <- datetime(Map.get(value, :observed_at)),
         {:ok, coverage} <- enum(Map.get(value, :coverage), @coverages),
         {:ok, numeric} <- numeric_facts(value),
         {:ok, duration_minutes} <- optional_non_negative_integer(Map.get(value, :duration_minutes)),
         {:ok, resets_at} <- optional_datetime(Map.get(value, :resets_at)),
         {:ok, expires_at} <- optional_datetime(Map.get(value, :expires_at)),
         {:ok, credits} <- optional_credits(Map.get(value, :credits)),
         {:ok, spend_control} <- optional_spend_control(Map.get(value, :spend_control)),
         :ok <- coverage_facts(coverage, standing, numeric, credits, spend_control) do
      {:ok,
       numeric
       |> Map.merge(%{
         limit_id: limit_id,
         kind: kind,
         name: name,
         standing: standing,
         source: source,
         observed_at: observed_at,
         expires_at: expires_at,
         duration_minutes: duration_minutes,
         resets_at: resets_at,
         credits: credits,
         spend_control: spend_control,
         coverage: coverage
       })
       |> Map.reject(fn {_key, item} -> is_nil(item) end)}
    else
      _ -> {:error, :invalid_window}
    end
  end

  defp window(_value), do: {:error, :invalid_window}

  defp numeric_facts(value) do
    [:used_percent, :remaining_percent, :used, :limit, :remaining]
    |> Enum.reduce_while({:ok, %{}}, fn key, {:ok, facts} ->
      case Map.fetch(value, key) do
        :error ->
          {:cont, {:ok, facts}}

        {:ok, number}
        when is_number(number) and number >= 0 and number <= @max_numeric and
               (key not in [:used_percent, :remaining_percent] or number <= 100) ->
          {:cont, {:ok, Map.put(facts, key, number)}}

        _ ->
          {:halt, {:error, :invalid_numeric_fact}}
      end
    end)
  end

  defp optional_plan(nil), do: {:ok, nil}

  defp optional_plan(plan) when is_map(plan) do
    with :ok <- only_keys?(plan, @plan_keys),
         {:ok, tier} <- enum(Map.get(plan, :tier), @plan_tiers),
         {:ok, source} <- enum(Map.get(plan, :source), @sources),
         {:ok, observed_at} <- datetime(Map.get(plan, :observed_at)),
         {:ok, expires_at} <- optional_datetime(Map.get(plan, :expires_at)) do
      {:ok, %{tier: tier, source: source, observed_at: observed_at, expires_at: expires_at}}
    else
      _ -> {:error, :invalid_plan}
    end
  end

  defp optional_plan(_plan), do: {:error, :invalid_plan}

  defp optional_credits(nil), do: {:ok, nil}

  defp optional_credits(credits) when is_map(credits) do
    with :ok <- only_keys?(credits, @credit_keys),
         {:ok, status} <- enum(Map.get(credits, :status), [:available, :exhausted, :unlimited, :unsupported]),
         {:ok, amount} <- optional_non_negative_number(Map.get(credits, :amount)),
         :ok <- unsupported_without_value(status, amount) do
      {:ok, %{status: status, amount: amount} |> Map.reject(fn {_key, item} -> is_nil(item) end)}
    else
      _ -> {:error, :invalid_credits}
    end
  end

  defp optional_credits(_credits), do: {:error, :invalid_credits}

  defp optional_spend_control(nil), do: {:ok, nil}

  defp optional_spend_control(control) when is_map(control) do
    with :ok <- only_keys?(control, @spend_control_keys),
         {:ok, status} <- enum(Map.get(control, :status), [:enabled, :disabled, :unsupported]),
         {:ok, limit} <- optional_non_negative_number(Map.get(control, :limit)),
         :ok <- unsupported_without_value(status, limit) do
      {:ok, %{status: status, limit: limit} |> Map.reject(fn {_key, item} -> is_nil(item) end)}
    else
      _ -> {:error, :invalid_spend_control}
    end
  end

  defp optional_spend_control(_control), do: {:error, :invalid_spend_control}

  defp generation_binding(%{binding: binding}) when is_reference(binding), do: {:ok, binding}
  defp generation_binding(binding) when is_reference(binding), do: {:ok, binding}
  defp generation_binding(_binding), do: {:error, :invalid_binding}

  defp limit_id(value) when is_binary(value) and byte_size(value) in 1..96 do
    if String.match?(value, ~r/^[A-Za-z0-9._:-]+$/), do: {:ok, value}, else: {:error, :invalid_limit_id}
  end

  defp limit_id(_value), do: {:error, :invalid_limit_id}
  defp human_name(name), do: Map.fetch(@window_names, name)
  defp enum(value, allowed), do: if(value in allowed, do: {:ok, value}, else: {:error, :invalid_enum})
  defp optional_enum(nil, _allowed), do: {:ok, nil}
  defp optional_enum(value, allowed), do: enum(value, allowed)
  defp datetime(%DateTime{} = value), do: {:ok, value}
  defp datetime(_value), do: {:error, :invalid_datetime}
  defp optional_datetime(nil), do: {:ok, nil}
  defp optional_datetime(value), do: datetime(value)
  defp positive_integer(value) when is_integer(value) and value in 1..@max_source_version, do: {:ok, value}
  defp positive_integer(_value), do: {:error, :invalid_positive_integer}
  defp optional_non_negative_integer(nil), do: {:ok, nil}
  defp optional_non_negative_integer(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp optional_non_negative_integer(_value), do: {:error, :invalid_non_negative_integer}
  defp optional_non_negative_number(nil), do: {:ok, nil}

  defp optional_non_negative_number(value)
       when is_number(value) and value >= 0 and value <= @max_numeric,
       do: {:ok, value}

  defp optional_non_negative_number(_value), do: {:error, :invalid_non_negative_number}
  defp coverage_facts(:supported, _standing, _numeric, _credits, _spend_control), do: :ok

  defp coverage_facts(coverage, standing, numeric, credits, spend_control)
       when coverage in [:unsupported, :empty_supported] do
    if is_nil(standing) and map_size(numeric) == 0 and absent_or_unsupported?(credits) and
         absent_or_unsupported?(spend_control) do
      :ok
    else
      {:error, :invalid_coverage_facts}
    end
  end

  defp absent_or_unsupported?(nil), do: true
  defp absent_or_unsupported?(%{status: :unsupported}), do: true
  defp absent_or_unsupported?(_fact), do: false
  defp unsupported_without_value(:unsupported, nil), do: :ok
  defp unsupported_without_value(:unsupported, _value), do: {:error, :invalid_unsupported_value}
  defp unsupported_without_value(_status, _value), do: :ok
  defp annotate_plan(nil, _source_version), do: nil
  defp annotate_plan(plan, source_version), do: Map.put(plan, :source_version, source_version)

  defp annotate_windows(windows, source_version) do
    Map.new(windows, fn {id, window} -> {id, Map.put(window, :source_version, source_version)} end)
  end

  defp only_keys?(map, allowed) do
    if Enum.all?(Map.keys(map), &Enum.member?(allowed, &1)), do: :ok, else: {:error, :unexpected_key}
  end

  defp equal?(left, right), do: if(left == right, do: :ok, else: {:error, :not_equal})
end
