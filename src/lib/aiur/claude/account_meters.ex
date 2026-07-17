defmodule Aiur.Claude.AccountMeters do
  @moduledoc false

  require Logger

  alias Aiur.Claude.{AccountGeneration, RateLimitAdapter}
  alias Aiur.ProviderMeters

  @redacted_method "provider_account/rate_limits_changed"

  @spec handle_notification(map(), map(), keyword()) :: :ok | {:error, atom()}
  def handle_notification(session, payload, opts \\ [])

  def handle_notification(session, payload, opts) when is_map(session) and is_map(payload) do
    observed_at = Keyword.get(opts, :observed_at, DateTime.utc_now())

    with binding when is_reference(binding) <- Map.get(session, :account_generation_binding),
         {:ok, update} <- RateLimitAdapter.snapshot(payload, binding, observed_at),
         {:ok, ^binding} <- AccountGeneration.observe(session, update.auth_mode) do
      ingest(session, update, observed_at)
    else
      {:error, reason} ->
        fail(session, reason, observed_at)

      _other ->
        fail(session, :malformed, observed_at)
    end
  end

  def handle_notification(_session, _payload, _opts), do: {:error, :malformed}

  @spec redacted_message() :: map()
  def redacted_message do
    %{payload: %{"method" => @redacted_method, "params" => %{}}, raw: nil}
  end

  defp ingest(session, update, observed_at) do
    case meter_ingester(session).(update) do
      {:ok, _snapshot} ->
        :ok

      _error ->
        fail(session, :malformed, observed_at)
    end
  end

  defp fail(session, reason, observed_at) do
    case record_failure(session, reason, observed_at) do
      :ok ->
        {:error, reason}

      {:error, :unknown_account_generation} ->
        {:error, :unknown_account_generation}

      {:error, :failure_recorder_rejected} ->
        Logger.error("Claude provider-meter failure could not be recorded: #{reason}")

        {:error, :provider_meter_failure_unrecorded}
    end
  end

  defp record_failure(session, reason, observed_at) do
    case AccountGeneration.trusted_binding(session) do
      {:ok, binding} -> record_failure(meter_failure_recorder(session), binding, reason, observed_at)
      :error -> {:error, :unknown_account_generation}
    end
  end

  defp record_failure(recorder, binding, reason, observed_at) do
    case recorder.(RateLimitAdapter.failure(binding, reason, observed_at)) do
      :ok -> :ok
      {:ok, _snapshot} -> :ok
      _error -> {:error, :failure_recorder_rejected}
    end
  end

  defp meter_ingester(session), do: Map.get(session, :provider_meter_ingester, &ProviderMeters.ingest/1)

  defp meter_failure_recorder(session),
    do: Map.get(session, :provider_meter_failure_recorder, &ProviderMeters.record_failure/1)
end
