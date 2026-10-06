defmodule Aiur.Muse.MeterProbe do
  @moduledoc """
  Normalizes Muse subscription observations without claiming account identity.

  The host scope is an in-memory reference supplied by the native session owner.
  It is never an account generation and must not be passed to ProviderMeters as
  a trusted binding. The owner retires it when that host exits or auth changes.
  """

  @max_percent 1_000_000_000_000

  @spec read((String.t() -> term()), reference()) :: {:ok, map()} | {:error, atom()}
  def read(request, host_scope) when is_function(request, 1) and is_reference(host_scope) do
    case request.("usage/read") do
      {:ok, result} -> normalize_read(result, host_scope)
      {:error, :timeout} -> {:error, :timeout}
      {:error, _reason} -> {:error, :unavailable}
      _other -> {:error, :invalid_read_result}
    end
  end

  @spec normalize_read(map(), reference()) :: {:ok, map()} | {:error, atom()}
  def normalize_read(%{"result" => %{"usage" => usage}}, host_scope), do: normalize_usage(usage, host_scope)
  def normalize_read(%{"usage" => usage}, host_scope), do: normalize_usage(usage, host_scope)
  def normalize_read(_result, _host_scope), do: {:error, :unavailable}

  @spec normalize_changed(map(), reference()) :: {:ok, map()} | {:error, atom()}
  def normalize_changed(%{"method" => "usage/changed", "params" => usage}, host_scope),
    do: normalize_usage(usage, host_scope)

  def normalize_changed(_event, _host_scope), do: {:error, :unsupported_usage_event}

  defp normalize_usage(nil, _host_scope), do: {:error, :unavailable}

  defp normalize_usage(%{"observedAtMs" => observed_ms, "window" => current, "weekly" => weekly} = usage, host_scope)
       when is_reference(host_scope) do
    with {:ok, observed_at} <- timestamp(observed_ms),
         {:ok, current} <- window(current, "muse.current", :current, observed_at),
         {:ok, weekly} <- window(weekly, "muse.weekly", :weekly, observed_at) do
      {:ok,
       %{
         identity: :unverified,
         host_scope: host_scope,
         observed_at: observed_at,
         auth_mode: :unknown,
         tier: tier(usage["tier"]),
         windows: [current, weekly]
       }}
    else
      _ -> {:error, :invalid_usage_observation}
    end
  end

  defp normalize_usage(_usage, _host_scope), do: {:error, :invalid_usage_observation}

  defp window(%{"usedPercent" => percent, "resetsAtMs" => reset_ms} = source, limit_id, name, observed_at) do
    with {:ok, percent} <- percent(percent),
         {:ok, resets_at} <- timestamp(reset_ms),
         {:ok, duration} <- duration(source["windowDurationMins"]) do
      {:ok,
       %{
         limit_id: limit_id,
         kind: :rate_limit,
         name: name,
         source: :provider,
         observed_at: observed_at,
         used_percent: percent,
         resets_at: resets_at,
         duration_minutes: duration,
         coverage: :supported
       }}
    end
  end

  defp window(_source, _id, _name, _observed_at), do: {:error, :invalid_window}

  defp percent(value) when is_number(value) and value >= 0 and value <= @max_percent, do: {:ok, value}
  defp percent(_value), do: {:error, :invalid_percent}
  defp duration(nil), do: {:ok, nil}
  defp duration(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp duration(_value), do: {:error, :invalid_duration}
  defp timestamp(value) when is_integer(value) and value >= 0, do: DateTime.from_unix(value, :millisecond)
  defp timestamp(_value), do: {:error, :invalid_timestamp}

  defp tier("free"), do: :free
  defp tier("pro"), do: :pro
  defp tier("team"), do: :team
  defp tier("business"), do: :business
  defp tier("enterprise"), do: :enterprise
  defp tier(_value), do: :unknown
end
