defmodule Aiur.DecisionStore do
  @moduledoc """
  The single public Decision application service and serialized writer.

  Every accepted mutation follows persist-before-notify: validate,
  compare against the current in-memory index, reserve a durably
  persisted event ID, append + fsync the canonical audit record,
  atomically replace the current-state projection, and only then
  publish to `Aiur.Events.Exchange` and broadcast on `Aiur.PubSub`. A
  request is rejected outright (no audit append, no notification) if
  validation fails or the durable ID reservation itself fails.

  On boot, replays the canonical audit stream, rebuilds the current
  projection, and repairs `decisions.json` if it doesn't already match.
  Interior corruption puts the store into a read-only mode: existing
  reads keep serving the validated prefix, every mutation is rejected,
  and one operator alert is emitted — never silently skipped.

  Version/dedup rules for a request against `decision_id`'s current
  state:

    * no current record — accepted only as version 1.
    * same version + same content hash — duplicate (returns the
      existing record; no append, no new notification).
    * same version + different content hash — idempotency conflict.
    * exactly `current version + 1` — accepted as the next version.
    * lower than current — stale.
    * anything else higher — a version gap.
  """

  use GenServer

  require Logger

  alias Aiur.{Alerts, Config, Decision, DecisionLog, DecisionProjection, DecisionPubSub, DecisionValidation, JsonStore}
  alias Aiur.Events.{IdGenerator, Publisher}

  @ndjson_filename "decisions.ndjson"
  @projection_filename "decisions.json"
  @request_timeout 60_000

  @type accept_result :: %{status: :accepted | :duplicate, decision: Decision.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Submits a `decision.requested` payload. `opts` carries the trusted
  `:ticket`/`:source` context (see `Aiur.DecisionValidation.normalize/2`);
  an optional `"version"`/`:version` key in `payload` states which
  version this request targets (defaults to `1`, i.e. a fresh Decision).
  """
  @spec request(map(), keyword(), GenServer.server(), timeout()) :: {:ok, accept_result()} | {:error, term()}
  def request(payload, opts \\ [], server \\ __MODULE__, timeout \\ @request_timeout)
      when is_map(payload) and is_list(opts) do
    GenServer.call(server, {:request, payload, opts}, timeout)
  end

  @spec get(String.t(), GenServer.server()) :: {:ok, Decision.t()} | {:error, :not_found}
  def get(decision_id, server \\ __MODULE__) when is_binary(decision_id) do
    GenServer.call(server, {:get, decision_id})
  end

  @spec list(GenServer.server()) :: [Decision.t()]
  def list(server \\ __MODULE__) do
    GenServer.call(server, :list)
  end

  @spec history(String.t(), GenServer.server()) :: {:ok, [Decision.t()]} | {:error, :not_found}
  def history(decision_id, server \\ __MODULE__) when is_binary(decision_id) do
    GenServer.call(server, {:history, decision_id})
  end

  @doc "`:writable`, or a reason tuple describing why the store is currently read-only/unavailable."
  @spec health(GenServer.server()) :: :writable | tuple()
  def health(server \\ __MODULE__) do
    GenServer.call(server, :health)
  end

  @impl true
  def init(opts) do
    case Config.Paths.decision_state_dir() do
      {:ok, dir} -> {:ok, boot(dir, Keyword.get(opts, :filesystem_sync_fun, &Aiur.Fs.sync_filesystem/0))}
      {:error, reason} -> {:ok, unavailable_state(nil, {:path_unresolved, reason})}
    end
  end

  defp boot(dir, filesystem_sync_fun) do
    ndjson_path = Path.join(dir, @ndjson_filename)
    projection_path = Path.join(dir, @projection_filename)

    case DecisionLog.prepare(dir, ndjson_path, filesystem_sync_fun) do
      :ok -> replay_and_project(ndjson_path, projection_path)
      {:error, reason} -> unavailable_state(ndjson_path, {:directory_unavailable, reason})
    end
  end

  defp replay_and_project(ndjson_path, projection_path) do
    case DecisionLog.replay(ndjson_path, &DecisionProjection.decode_record/1) do
      {:ok, records, corruption} ->
        %{current: current, history: history} = DecisionProjection.reduce(records)

        %{
          ndjson_path: ndjson_path,
          projection_path: projection_path,
          current: current,
          history: history,
          writable?: true,
          health: :writable
        }
        |> repair_projection()
        |> apply_corruption(corruption)

      {:error, reason} ->
        unavailable_state(ndjson_path, {:replay_failed, reason})
    end
  end

  defp apply_corruption(state, nil), do: state

  defp apply_corruption(state, {:corrupt, line, reason}) do
    Logger.error("aiur_decision_store phase=corruption path=#{state.ndjson_path} line=#{line} reason=#{inspect(reason)}")

    _ =
      Alerts.emit_custom(
        "decision_store.corrupted",
        "DecisionStore audit log corrupt at #{state.ndjson_path} line #{line} (#{inspect(reason)}); store is read-only.",
        needs_attention: true
      )

    %{state | writable?: false, health: {:corrupt, line, reason}}
  end

  defp unavailable_state(ndjson_path, reason) do
    Logger.error("aiur_decision_store phase=unavailable reason=#{inspect(reason)}")

    %{
      ndjson_path: ndjson_path,
      projection_path: nil,
      current: %{},
      history: %{},
      writable?: false,
      health: {:unavailable, reason}
    }
  end

  defp repair_projection(state) do
    case write_projection(state) do
      :ok ->
        state

      {:error, reason} ->
        Logger.error("aiur_decision_store phase=projection_repair_failed reason=#{inspect(reason)}")

        _ =
          Alerts.emit_custom(
            "decision_store.repair_failed",
            "DecisionStore's decisions.json projection failed to write (#{inspect(reason)}); the audit record stays authoritative, but the store is read-only until repaired.",
            needs_attention: true
          )

        %{state | writable?: false, health: {:repair, reason}}
    end
  end

  defp write_projection(%{projection_path: nil}), do: {:error, :no_projection_path}

  defp write_projection(state) do
    JsonStore.write!(state.projection_path, DecisionProjection.serialize_current(state.current))
    # JsonStore is a shared primitive with no opinion on permissions (other
    # consumers don't need owner-only); Decision content does, so chmod it
    # here rather than widening JsonStore's contract for every caller.
    File.chmod!(state.projection_path, 0o600)
    :ok
  rescue
    error -> {:error, Exception.message(error)}
  end

  @impl true
  def handle_call({:request, _payload, _opts}, _from, %{writable?: false} = state) do
    {:reply, {:error, {:store_unavailable, state.health}}, state}
  end

  def handle_call({:request, payload, opts}, _from, state) do
    handle_request(payload, opts, state)
  end

  def handle_call({:get, decision_id}, _from, state) do
    case Map.fetch(state.current, decision_id) do
      {:ok, decision} -> {:reply, {:ok, decision}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list, _from, state) do
    {:reply, Map.values(state.current), state}
  end

  def handle_call({:history, decision_id}, _from, state) do
    case Map.fetch(state.history, decision_id) do
      {:ok, history} -> {:reply, {:ok, history}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:health, _from, state) do
    {:reply, state.health, state}
  end

  defp handle_request(payload, opts, state) do
    with {:ok, requested_version} <- fetch_requested_version(payload),
         {:ok, decision} <- DecisionValidation.normalize(payload, opts) do
      evaluate_and_apply(decision, requested_version, state)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp fetch_requested_version(payload) do
    case Map.get(payload, "version", Map.get(payload, :version)) do
      nil -> {:ok, 1}
      version when is_integer(version) and version > 0 -> {:ok, version}
      _other -> {:error, {:version, :invalid_type}}
    end
  end

  defp evaluate_and_apply(decision, requested_version, state) do
    case evaluate(decision, requested_version, state) do
      {:duplicate, existing} -> {:reply, {:ok, %{status: :duplicate, decision: existing}}, state}
      {:reject, reason} -> {:reply, {:error, {:conflict, reason}}, state}
      {:accept, decision} -> accept(decision, state)
    end
  end

  defp evaluate(decision, requested_version, state) do
    case Map.get(state.current, decision.decision_id) do
      nil -> evaluate_fresh(decision, requested_version)
      existing -> evaluate_against_existing(decision, requested_version, existing)
    end
  end

  defp evaluate_fresh(decision, 1), do: {:accept, %{decision | version: 1}}
  defp evaluate_fresh(_decision, requested_version), do: {:reject, {:version_gap, requested_version, nil}}

  defp evaluate_against_existing(decision, requested_version, existing) do
    cond do
      requested_version == existing.version and decision.content_hash == existing.content_hash ->
        {:duplicate, existing}

      requested_version == existing.version ->
        {:reject, {:idempotency_conflict, requested_version}}

      requested_version == existing.version + 1 ->
        {:accept, %{decision | version: requested_version}}

      requested_version < existing.version ->
        {:reject, {:stale_version, requested_version, existing.version}}

      true ->
        {:reject, {:version_gap, requested_version, existing.version}}
    end
  end

  defp accept(decision, state) do
    case IdGenerator.reserve_durable_id() do
      {:ok, event_id} -> persist_and_notify(decision, event_id, state)
      {:error, :not_durable} -> {:reply, {:error, :event_id_not_durable}, state}
    end
  end

  defp persist_and_notify(decision, event_id, state) do
    record = decision |> DecisionProjection.to_json_safe() |> Map.put("event_id", event_id)

    case DecisionLog.append(state.ndjson_path, record) do
      :ok ->
        new_state =
          %{
            state
            | current: Map.put(state.current, decision.decision_id, decision),
              history: Map.update(state.history, decision.decision_id, [decision], &(&1 ++ [decision]))
          }
          |> repair_projection()

        notify(decision, event_id)
        {:reply, {:ok, %{status: :accepted, decision: decision}}, new_state}

      {:error, reason} ->
        {:reply, {:error, {:append_failed, reason}}, state}
    end
  end

  defp notify(decision, event_id) do
    topic = "ticket.#{decision.ticket.identifier}.agent.decision.requested"
    payload = DecisionProjection.to_json_safe(decision)

    try do
      Publisher.publish_persisted(topic, payload, event_id)
    rescue
      error -> Logger.warning("aiur_decision_store phase=notify_publisher_failed error=#{Exception.message(error)}")
    end

    try do
      DecisionPubSub.broadcast_changed(decision.decision_id, decision.version)
    rescue
      error -> Logger.warning("aiur_decision_store phase=notify_pubsub_failed error=#{Exception.message(error)}")
    end

    :ok
  end
end
