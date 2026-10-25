defmodule Aiur.Claude.Telemetry.LaunchRegistry do
  @moduledoc false
  # Pure state functions behind launch preparation, authorization, release and
  # revocation for `Aiur.Claude.Telemetry`. State in, state out; this module
  # never calls `GenServer`.

  alias Aiur.{Boot, Issue, TrackerIdentity}
  alias Aiur.Claude.Telemetry.Contract

  @doc false
  @spec validate_launch_request(term(), term()) :: term()
  def validate_launch_request(%{backend: backend, worker_host: nil, worker_generation: generation, issue: issue}, state)
      when backend in ["claude", "claude-repl"] and is_integer(generation) and generation > 0 and is_integer(state.port) do
    if TrackerIdentity.joinable?(Issue.tracker_identity(issue)), do: :ok, else: {:error, :missing_tracker_identity}
  end

  def validate_launch_request(%{worker_host: worker_host}, _state) when is_binary(worker_host), do: {:error, :remote_worker_unsupported}
  def validate_launch_request(_request, _state), do: {:error, :invalid_correlation}

  @doc false
  @spec correlation(term()) :: term()
  def correlation(%{issue: issue, attempt_id: attempt_id, worker_generation: worker_generation, backend: backend})
      when is_binary(attempt_id) and backend in ["claude", "claude-repl"] do
    {:ok,
     %{
       run_id: Boot.run_id(),
       ticket: Issue.tracker_identity(issue),
       attempt_id: attempt_id,
       worker_generation: worker_generation,
       producer_generation: "producer-#{System.unique_integer([:positive, :monotonic])}",
       backend: backend
     }}
  end

  def correlation(_request), do: {:error, :invalid_correlation}

  @doc false
  @spec launch_env(term(), term()) :: term()
  def launch_env(port, capability) do
    endpoint = endpoint_from_port(port) <> "/v1/logs"

    [
      {"CLAUDE_CODE_ENABLE_TELEMETRY", "1"},
      {"OTEL_LOGS_EXPORTER", "otlp"},
      {"OTEL_METRICS_EXPORTER", "none"},
      {"OTEL_TRACES_EXPORTER", "none"},
      {"OTEL_EXPORTER_OTLP_PROTOCOL", "http/json"},
      {"OTEL_EXPORTER_OTLP_LOGS_PROTOCOL", "http/json"},
      {"OTEL_EXPORTER_OTLP_LOGS_ENDPOINT", endpoint},
      {"OTEL_EXPORTER_OTLP_HEADERS", "Authorization=Bearer #{capability}"},
      {"OTEL_EXPORTER_OTLP_LOGS_HEADERS", "Authorization=Bearer #{capability}"},
      {"OTEL_LOG_USER_PROMPTS", "0"},
      {"OTEL_LOG_ASSISTANT_RESPONSES", "0"},
      {"OTEL_LOG_TOOL_DETAILS", "0"},
      {"OTEL_LOG_TOOL_CONTENT", "0"},
      {"OTEL_LOG_RAW_API_BODIES", "0"},
      {"OTEL_RESOURCE_ATTRIBUTES", false}
    ]
  end

  @doc false
  @spec source_contract() :: term()
  def source_contract do
    %{
      emitter_version: Contract.emitter_version(),
      service_name: Contract.service_name(),
      source_version: Contract.source_version()
    }
  end

  @doc false
  @spec bearer_capability(term()) :: term()
  def bearer_capability("Bearer " <> capability) when byte_size(capability) == 43, do: {:ok, capability}
  def bearer_capability(_header), do: {:error, :unauthenticated}

  @doc false
  @spec available?(term(), term()) :: term()
  def available?(%{inflight: inflight}, %{max_inflight: max}) when inflight < max, do: :ok
  def available?(_entry, _state), do: {:error, :concurrent_limit}

  @doc false
  @spec take_rate_slots(term(), term(), term()) :: term()
  def take_rate_slots(entry, state, event_count) when is_integer(event_count) and event_count > 0 do
    current = now(state)
    elapsed = current - entry.rate_started_at
    entry = if elapsed >= state.rate_window_ms, do: %{entry | rate_started_at: current, rate_count: 0}, else: entry

    if entry.rate_count + event_count <= state.max_events_per_window do
      {:ok, %{entry | rate_count: entry.rate_count + event_count}}
    else
      {:error, :rate_limited}
    end
  end

  def take_rate_slots(entry, _state, 0), do: {:ok, entry}

  @doc false
  @spec release_inflight_request(term(), term()) :: term()
  def release_inflight_request(state, request_id) do
    case Map.pop(state.requests, request_id) do
      {nil, _requests} ->
        state

      {capability, requests} ->
        capabilities =
          case Map.fetch(state.capabilities, capability) do
            {:ok, entry} ->
              Map.put(state.capabilities, capability, %{entry | inflight: max(entry.inflight - 1, 0)})

            :error ->
              state.capabilities
          end

        %{state | requests: requests, capabilities: capabilities}
    end
  end

  @spec revoke_matching_ticket(term(), term()) :: term()
  def revoke_matching_ticket(state, ticket) do
    launch_ids =
      state.capabilities
      |> Enum.filter(fn {_, entry} -> entry.correlation.ticket == ticket end)
      |> Enum.map(fn {_, entry} -> entry.launch_id end)

    {Enum.reduce(launch_ids, state, fn launch_id, acc -> revoke_launch(acc, launch_id) end), launch_ids != []}
  end

  @doc false
  @spec revoke_launch(term(), term()) :: term()
  def revoke_launch(state, launch_id) do
    case Map.pop(state.launch_ids, launch_id) do
      {nil, _launch_ids} ->
        state

      {capability, launch_ids} ->
        revoke_capability(state, capability, launch_ids)
    end
  end

  @spec revoke_capability(term(), term(), term()) :: term()
  def revoke_capability(state, capability, launch_ids) do
    case Map.pop(state.capabilities, capability) do
      {nil, _capabilities} ->
        %{state | launch_ids: launch_ids}

      {entry, capabilities} ->
        revoke_capability_entry(state, capability, launch_ids, entry, capabilities)
    end
  end

  @doc false
  @spec revoke_capability_entry(term(), term(), term(), term(), term()) :: term()
  def revoke_capability_entry(state, capability, launch_ids, entry, capabilities) do
    demonitor_owner(entry.owner_monitor)

    %{
      state
      | capabilities: capabilities,
        launch_ids: launch_ids,
        requests: drop_capability_requests(state.requests, capability)
    }
  end

  @doc false
  @spec demonitor_owner(term()) :: term()
  def demonitor_owner(monitor) when is_reference(monitor), do: Process.demonitor(monitor, [:flush])
  def demonitor_owner(_monitor), do: :ok

  @doc false
  @spec drop_capability_requests(term(), term()) :: term()
  def drop_capability_requests(requests, capability) do
    requests
    |> Enum.reject(fn {_request_id, request_capability} -> request_capability == capability end)
    |> Map.new()
  end

  @spec count_rejection(term(), term()) :: term()
  def count_rejection(state, reason) do
    reason =
      if reason in [
           :unauthenticated,
           :unknown_capability,
           :concurrent_limit,
           :rate_limited,
           :replay,
           :stale_session,
           :malformed,
           :oversize,
           :unsupported_event,
           :unsupported_version,
           :attribute_limit,
           :unknown_request,
           :capability_unavailable,
           :missing_tracker_identity,
           :remote_worker_unsupported,
           :invalid_correlation
         ], do: reason, else: :other

    %{state | rejections: Map.update(state.rejections, reason, 1, &(&1 + 1))}
  end

  @doc false
  @spec endpoint_from_port(term()) :: term()
  def endpoint_from_port(port) when is_integer(port) and port > 0, do: "http://127.0.0.1:#{port}"
  def endpoint_from_port(_port), do: nil

  @doc false
  @spec mint_capability(term()) :: term()
  def mint_capability(%{capability_fun: fun, capabilities: capabilities}) when is_function(fun, 0) do
    case fun.() do
      capability when is_binary(capability) ->
        if valid_capability?(capability) and not is_map_key(capabilities, capability) do
          {:ok, capability}
        else
          {:error, :capability_unavailable}
        end

      _ ->
        {:error, :capability_unavailable}
    end
  end

  def mint_capability(_state), do: {:error, :capability_unavailable}

  @spec capability() :: term()
  def capability, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  @spec valid_capability?(term()) :: term()
  def valid_capability?(capability) do
    case Base.url_decode64(capability, padding: false) do
      {:ok, bytes} -> byte_size(bytes) == 32
      :error -> false
    end
  end

  @doc false
  @spec now(term()) :: term()
  def now(%{clock: clock}), do: clock.()
  @doc false
  @spec monitor_owner(term()) :: term()
  def monitor_owner(owner) when is_pid(owner), do: Process.monitor(owner)
  def monitor_owner(_owner), do: nil
  @doc false
  @spec worker_generation(term()) :: term()
  def worker_generation(%{generation: generation}) when is_integer(generation), do: generation
  def worker_generation(_ownership), do: nil
end
