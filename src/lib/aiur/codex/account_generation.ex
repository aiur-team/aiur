defmodule Aiur.Codex.AccountGeneration do
  @moduledoc false

  alias Aiur.Codex.{AccountGeneration.Context, RateLimitAdapter, RateLimits}
  alias Aiur.{ProviderAccountGeneration, ProviderMeters}

  @account_updated "account/updated"
  @token_refresh "account/chatgptAuthTokens/refresh"
  @rate_limits_updated "account/rateLimits/updated"

  @authentication_changed "provider_account/authentication_changed"
  @authentication_refreshed "provider_account/authentication_refreshed"
  @rate_limits_changed "provider_account/rate_limits_changed"
  @unknown_lifecycle "provider_account/unknown_lifecycle"

  @account_updated_auth_modes ~w(apikey chatgpt chatgptAuthTokens headers agentIdentity personalAccessToken bedrockApiKey)

  @spec new_binding(GenServer.server()) :: map()
  def new_binding(server \\ ProviderAccountGeneration), do: Context.new_binding(server)

  @spec handle_notification(map(), String.t(), map()) :: :ignore | {:redacted, map()}
  def handle_notification(session, @account_updated, payload) when is_map(session) and is_map(payload) do
    case account_updated_auth_mode(payload) do
      {:ok, auth_mode} -> bind_account(session, auth_mode)
      :logout -> lose_continuity(session, :logout)
      :error -> lose_continuity(session, :unsupported_auth_mode)
    end

    {:redacted, redacted_message(@account_updated)}
  end

  def handle_notification(session, @token_refresh, payload) when is_map(session) and is_map(payload) do
    confirm_account_binding(session)
    {:redacted, redacted_message(@token_refresh)}
  end

  def handle_notification(session, @rate_limits_updated, payload) when is_map(session) and is_map(payload) do
    case submit_rate_limit_patch(session, raw_rate_limits(payload)) do
      result when result in [:ok, :ignore] ->
        rate_limits = RateLimits.from_notification(payload)
        observe_rate_limits(session, rate_limits)
        {:redacted, redacted_message(@rate_limits_updated, rate_limits)}

      :error ->
        {:redacted, redacted_message(@rate_limits_updated)}
    end
  end

  def handle_notification(session, <<"account/", _rest::binary>> = method, _payload) when is_map(session) do
    lose_continuity(session, :untrusted_lifecycle)
    {:redacted, redacted_message(method)}
  end

  def handle_notification(_session, _method, _payload), do: :ignore

  @doc "Seeds the binding from Handshake's privacy-reduced account/read result."
  @spec seed_from_account_read(map(), map()) :: :ok
  def seed_from_account_read(session, %{auth_mode: auth_mode}) when auth_mode in @account_updated_auth_modes do
    bind_account(session, auth_mode)
    :ok
  end

  def seed_from_account_read(session, _response) when is_map(session) do
    lose_continuity(session, :no_authenticated_account)
    :ok
  end

  def seed_from_account_read(_session, _response), do: :ok

  @spec observe_rate_limit_snapshot(map(), map(), keyword()) :: map() | nil
  def observe_rate_limit_snapshot(session, response, opts \\ [])

  def observe_rate_limit_snapshot(session, response, opts) when is_map(session) and is_map(response) do
    case submit_rate_limit_snapshot(session, response, opts) do
      result when result in [:ok, :ignore] ->
        rate_limits = RateLimits.from_read_response(response)
        observe_rate_limits(session, rate_limits)
        rate_limits

      :error ->
        nil
    end
  end

  def observe_rate_limit_snapshot(_session, _response, _opts), do: nil

  @spec record_rate_limit_failure(map(), term(), keyword()) :: :ok
  def record_rate_limit_failure(session, reason, opts \\ []) when is_map(session) do
    with {:ok, _server, binding, _authority, _topic} <- Context.fetch(session) do
      failure = RateLimitAdapter.failure(binding, reason, observed_at(opts))
      meter_failure_recorder(session).(failure)
    end

    :ok
  end

  @spec process_stopped(map()) :: :ok
  def process_stopped(session) when is_map(session) do
    retire_binding(session, :continuity_lost)
    Context.clear(session)
    :ok
  end

  defp bind_account(session, auth_mode) do
    Context.clear_rate_limit_ids(session)

    with_recovered_binding(session, fn server, binding, authority ->
      ProviderAccountGeneration.bind(server, :codex, :app_server, binding,
        source: :codex_app_server,
        auth_mode: auth_mode,
        authority: authority
      )
    end)

    Context.put_auth_mode(session, auth_mode)
  end

  defp confirm_account_binding(session) do
    with_recovered_binding(session, fn server, binding, authority ->
      ProviderAccountGeneration.confirm(server, :codex, :app_server, binding,
        source: :codex_app_server,
        authority: authority
      )
    end)
  end

  defp lose_continuity(session, reason) do
    with_recovered_binding(session, fn server, binding, authority ->
      ProviderAccountGeneration.invalidate(server, :codex, :app_server, binding,
        source: :codex_app_server,
        reason: reason,
        authority: authority
      )
    end)

    Context.clear_auth_mode(session)
  end

  defp with_recovered_binding(session, transition) when is_function(transition, 3) do
    with {:ok, server, binding, authority, topic} <- Context.fetch(session),
         :ok <- recover_retained_binding(server, binding, authority, topic) do
      transition.(server, binding, authority)
    end

    :ok
  end

  defp retire_binding(session, reason) do
    with_recovered_binding(session, fn server, binding, authority ->
      ProviderAccountGeneration.retire(server, :codex, :app_server, binding,
        source: :codex_app_server,
        reason: reason,
        authority: authority
      )
    end)

    :ok
  end

  defp recover_retained_binding(server, binding, authority, topic) do
    ProviderAccountGeneration.recover_binding(server, :codex, :app_server, %{
      binding: binding,
      authority: authority,
      topic: topic
    })
  end

  defp account_updated_auth_mode(%{"params" => %{"authMode" => nil}}), do: :logout

  defp account_updated_auth_mode(%{"params" => %{"authMode" => auth_mode}}) when auth_mode in @account_updated_auth_modes,
    do: {:ok, auth_mode}

  defp account_updated_auth_mode(_payload), do: :error

  defp observe_rate_limits(%{rate_limit_observer: observer}, rate_limits) when is_map(rate_limits) do
    observer.("codex", rate_limits)
  end

  defp observe_rate_limits(_session, _rate_limits), do: :ok

  defp submit_rate_limit_snapshot(session, response, opts) do
    case Context.fetch(session) do
      {:ok, _server, binding, _authority, _topic} ->
        case RateLimitAdapter.snapshot(response, binding, RateLimitAdapter.auth_mode(Context.auth_mode(session)), observed_at(opts)) do
          {:ok, update} ->
            case ingest_rate_limit_update(session, update, opts) do
              :ok ->
                with {:ok, limit_ids} <- RateLimitAdapter.snapshot_limit_ids(response) do
                  Context.put_rate_limit_ids(session, limit_ids)
                end

                :ok

              :error ->
                :error
            end

          {:error, reason} ->
            record_rate_limit_failure(session, reason, opts) && :error
        end

      :error ->
        :error
    end
  end

  defp submit_rate_limit_patch(session, rate_limits) when is_map(rate_limits) do
    case Context.fetch(session) do
      {:ok, _server, binding, _authority, _topic} ->
        case RateLimitAdapter.patch(
               rate_limits,
               binding,
               RateLimitAdapter.auth_mode(Context.auth_mode(session)),
               DateTime.utc_now(),
               single_limit_id: Context.single_rate_limit_id(session)
             ) do
          {:ok, update} ->
            ingest_rate_limit_update(session, update, [])

          :ignore ->
            if trusted_generation?(session) do
              :ignore
            else
              record_rate_limit_failure(session, :malformed) && :error
            end

          {:error, reason} ->
            record_rate_limit_failure(session, reason) && :error
        end

      :error ->
        :error
    end
  end

  defp submit_rate_limit_patch(session, _rate_limits) do
    record_rate_limit_failure(session, :malformed)
    :error
  end

  defp ingest_rate_limit_update(session, update, opts) do
    case meter_ingester(session).(update) do
      {:ok, _snapshot} ->
        :ok

      {:error, _reason} ->
        record_rate_limit_failure(session, :malformed, opts)
        :error

      _other ->
        record_rate_limit_failure(session, :malformed, opts)
        :error
    end
  end

  defp trusted_generation?(session) do
    with {:ok, server, binding, _authority, _topic} <- Context.fetch(session),
         %{generation: generation, freshness: :current, health: :healthy} <-
           ProviderAccountGeneration.lookup(server, :codex, :app_server, binding),
         true <- is_binary(generation) do
      true
    else
      _ -> false
    end
  end

  # Older Codex versions publish an explicitly limited/unlimited scheduling
  # signal without canonical facts. It remains a conservative compatibility
  # feed only; structured malformed data never reaches that path.
  defp raw_rate_limits(%{"params" => %{"rateLimits" => rate_limits}}) when is_map(rate_limits), do: rate_limits
  defp raw_rate_limits(_payload), do: nil
  defp meter_ingester(session), do: Map.get(session, :provider_meter_ingester, &ProviderMeters.ingest/1)
  defp meter_failure_recorder(session), do: Map.get(session, :provider_meter_failure_recorder, &ProviderMeters.record_failure/1)
  defp observed_at(opts), do: Keyword.get(opts, :observed_at, DateTime.utc_now())

  defp redacted_message(method), do: %{payload: %{"method" => redacted_method(method), "params" => %{}}, raw: nil}

  defp redacted_message(method, nil), do: redacted_message(method)

  defp redacted_message(method, rate_limits) do
    %{payload: %{"method" => redacted_method(method), "params" => %{}}, raw: nil, rate_limits: rate_limits}
  end

  defp redacted_method(@account_updated), do: @authentication_changed
  defp redacted_method(@token_refresh), do: @authentication_refreshed
  defp redacted_method(@rate_limits_updated), do: @rate_limits_changed
  defp redacted_method(<<"account/", _rest::binary>>), do: @unknown_lifecycle
end
