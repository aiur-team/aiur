defmodule Aiur.Claude.AccountMeters do
  @moduledoc false

  alias Aiur.Claude.{AccountGeneration, RateLimitAdapter}
  alias Aiur.ProviderMeters

  @redacted_method "provider_account/rate_limits_changed"

  @spec handle_notification(map(), map(), keyword()) :: :ok | {:error, atom()}
  def handle_notification(session, payload, opts \\ [])

  def handle_notification(session, payload, opts) when is_map(session) and is_map(payload) do
    observed_at = Keyword.get(opts, :observed_at, DateTime.utc_now())

    with binding when is_reference(binding) <- Map.get(session, :account_generation_binding),
         {:ok, update} <- RateLimitAdapter.snapshot(payload, binding, observed_at),
         {:ok, ^binding} <- AccountGeneration.observe(session, update.auth_mode),
         {:ok, _snapshot} <- meter_ingester(session).(update) do
      :ok
    else
      {:error, reason} ->
        record_failure(session, reason, observed_at)
        {:error, reason}

      _other ->
        record_failure(session, :malformed, observed_at)
        {:error, :malformed}
    end
  end

  def handle_notification(_session, _payload, _opts), do: {:error, :malformed}

  @spec redacted_message() :: map()
  def redacted_message do
    %{payload: %{"method" => @redacted_method, "params" => %{}}, raw: nil}
  end

  defp record_failure(session, reason, observed_at) do
    with {:ok, binding} <- AccountGeneration.trusted_binding(session) do
      recorder = meter_failure_recorder(session)
      recorder.(RateLimitAdapter.failure(binding, reason, observed_at))
    end

    :ok
  end

  defp meter_ingester(session), do: Map.get(session, :provider_meter_ingester, &ProviderMeters.ingest/1)

  defp meter_failure_recorder(session),
    do: Map.get(session, :provider_meter_failure_recorder, &ProviderMeters.record_failure/1)
end
