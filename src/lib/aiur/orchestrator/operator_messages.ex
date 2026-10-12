defmodule Aiur.Orchestrator.OperatorMessages do
  @moduledoc """
  Queues and routes Executor messages and event digests to running agents. All functions execute inside the orchestrator GenServer process.
  """
  alias Aiur.{AgentQueueStore, TrackerIdentity}

  alias Aiur.Orchestrator.State

  alias Aiur.Orchestrator.OperatorMessages.{Calls, Capabilities, ControlAlerts, DeliveryPolicy, Enqueue}
  @operator_message_call_timeout_ms 5_000

  @spec send_operator_message(String.t() | TrackerIdentity.t(), map()) ::
          {:ok, integer()} | {:error, term()}
  def send_operator_message(issue_identifier, payload),
    do: send_operator_message(Aiur.Orchestrator, issue_identifier, payload)

  @spec send_operator_message(GenServer.server(), String.t() | TrackerIdentity.t(), map()) ::
          {:ok, integer()} | {:error, term()}
  def send_operator_message(server, issue_identifier, payload) do
    timeout = operator_message_call_timeout_ms()

    server
    |> control_api_call({:send_operator_message, issue_identifier, payload}, timeout)
    |> reconcile_send_timeout(
      server,
      {:message_id, Enqueue.payload_key(payload, :message_id)},
      timeout,
      &{:ok, &1.id},
      expected_message(issue_identifier, payload)
    )
  end

  # The lookup after a timeout must prove the item is this send, not an older
  # message that reused the id with other text (#2717).
  defp expected_message(issue_identifier, %{body: body}) when is_binary(body),
    do: %{target: issue_identifier, text: body}

  defp expected_message(_issue_identifier, _payload), do: nil

  @doc "Send one idempotent action-correlated Executor message and return its queue snapshot."
  @spec send_correlated_operator_message(String.t(), map()) ::
          {:ok, %{status: :accepted | :duplicate | :retried, item: Aiur.AgentQueueItem.t()}}
          | {:error, term()}
  def send_correlated_operator_message(issue_identifier, payload),
    do: send_correlated_operator_message(Aiur.Orchestrator, issue_identifier, payload)

  @spec send_correlated_operator_message(GenServer.server(), String.t(), map()) ::
          {:ok, %{status: :accepted | :duplicate | :retried, item: Aiur.AgentQueueItem.t()}}
          | {:error, term()}
  def send_correlated_operator_message(server, issue_identifier, payload) do
    timeout = operator_message_call_timeout_ms()

    server
    |> control_api_call({:send_correlated_operator_message, issue_identifier, payload}, timeout)
    |> reconcile_send_timeout(
      server,
      {:action_id, Enqueue.payload_key(payload, :action_id)},
      timeout,
      &{:ok, %{status: :duplicate, item: &1}}
    )
  end

  # A caller-side timeout does not mean the Orchestrator dropped the send: the
  # call stays in its mailbox and can still queue the item seconds later
  # (#2717). The lookup is sent from the same process to the same server, so
  # it is handled after the send. If it finds the item, the send is reported
  # with that item. If it proves no item exists, nothing was queued. If it
  # also times out, the outcome is unknown, never a failure, and a retry with
  # the same key is safe because enqueue is idempotent by that key.
  defp reconcile_send_timeout(result, server, lookup, timeout, found, expected \\ nil)

  defp reconcile_send_timeout({:error, :timeout}, server, {_kind, key} = lookup, timeout, found, expected)
       when is_binary(key) do
    case control_api_call(server, lookup_request(lookup, expected), timeout) do
      {:ok, item} -> found.(item)
      {:error, :unknown_message} -> {:error, {:not_queued, :timeout}}
      {:error, {:message_id_conflict, _item_id}} = conflict -> conflict
      {:error, _reason} -> {:error, {:outcome_unknown, outcome_unknown_info(lookup)}}
    end
  end

  defp reconcile_send_timeout({:error, :timeout}, _server, lookup, _timeout, _found, _expected),
    do: {:error, {:outcome_unknown, outcome_unknown_info(lookup)}}

  defp reconcile_send_timeout(result, _server, _lookup, _timeout, _found, _expected), do: result

  defp lookup_request(lookup, nil), do: {:lookup_operator_message, lookup}
  defp lookup_request(lookup, expected), do: {:lookup_operator_message, lookup, expected}

  defp outcome_unknown_info({kind, key}), do: %{kind => key, item_id: nil}

  @doc false
  @spec operator_message_call_timeout_ms() :: pos_integer()
  def operator_message_call_timeout_ms,
    do: Application.get_env(:aiur, :operator_message_call_timeout_ms, @operator_message_call_timeout_ms)

  @doc """
  Read the queue status of one enqueued operator message by its request id.

  `send_operator_message/2` answers with a queue handle, not a delivery
  receipt. This is the correlation read that turns that handle into an
  observed outcome: `:pending` means still queued, `:delivered` means the
  agent claimed it, `:consumed` means the agent finished acting on it.
  """
  @spec operator_message_status(GenServer.server(), integer(), timeout()) ::
          {:ok, Aiur.AgentQueueItem.status()} | {:error, term()}
  def operator_message_status(server, item_id, timeout \\ 5_000) when is_integer(item_id),
    do: control_api_call(server, {:operator_message_status, item_id}, timeout)

  @spec control_capabilities(String.t()) :: {:ok, map()} | {:error, term()}
  def control_capabilities(issue_identifier),
    do: control_capabilities(Aiur.Orchestrator, issue_identifier)

  @spec control_capabilities(GenServer.server(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def control_capabilities(server, issue_identifier) when is_binary(issue_identifier),
    do: control_api_call(server, {:control_capabilities, issue_identifier}, 5_000)

  @spec claim_next_queue_item(GenServer.server(), String.t()) ::
          {:ok, map()} | :empty | {:error, term()}
  def claim_next_queue_item(server, issue_identifier) when is_binary(issue_identifier),
    do: queue_api_call(server, {:claim_next_queue_item, issue_identifier}, :infinity)

  @spec claim_next_checkpoint_queue_item(GenServer.server(), String.t()) ::
          {:ok, map()} | :empty | {:error, term()}
  def claim_next_checkpoint_queue_item(server, issue_identifier)
      when is_binary(issue_identifier),
      do: queue_api_call(server, {:claim_next_checkpoint_queue_item, issue_identifier}, :infinity)

  @spec claim_blocker_critical_events_digest(GenServer.server(), String.t()) ::
          {:ok, map()} | :empty | {:error, term()}
  def claim_blocker_critical_events_digest(server, issue_identifier)
      when is_binary(issue_identifier),
      do: queue_api_call(server, {:claim_blocker_critical_events_digest, issue_identifier}, :infinity)

  @spec claim_next_operator_queue_item(GenServer.server(), String.t()) ::
          {:ok, map()} | :empty | {:error, term()}
  def claim_next_operator_queue_item(server, issue_identifier)
      when is_binary(issue_identifier),
      do: queue_api_call(server, {:claim_next_operator_queue_item, issue_identifier}, :infinity)

  @spec claim_operator_response(GenServer.server(), String.t(), String.t()) :: {:ok, map()} | :empty | {:error, term()}
  def claim_operator_response(server, identifier, command) when is_binary(command) and command != "" do
    queue_api_call(server, {:claim_operator_response, identifier, command}, :infinity)
  end

  @spec mark_queue_item_consumed(GenServer.server(), integer()) :: :ok | {:error, term()}
  def mark_queue_item_consumed(server, item_id) when is_integer(item_id),
    do: queue_api_call(server, {:mark_queue_item_consumed, item_id})

  @spec restore_queue_item_pending(GenServer.server(), integer()) :: :ok | {:error, term()}
  def restore_queue_item_pending(server, item_id) when is_integer(item_id),
    do: queue_api_call(server, {:restore_queue_item_pending, item_id})

  @spec mark_queue_item_failed(GenServer.server(), integer(), term()) ::
          :ok | {:error, term()}
  def mark_queue_item_failed(server, item_id, reason) when is_integer(item_id),
    do: queue_api_call(server, {:mark_queue_item_failed, item_id, reason})

  @spec acknowledge_queue_item_delivery(GenServer.server(), integer(), map()) ::
          :ok | {:error, term()}
  def acknowledge_queue_item_delivery(server, item_id, provider_metadata)
      when is_integer(item_id) and is_map(provider_metadata),
      do:
        queue_api_call(
          server,
          {:acknowledge_queue_item_delivery, item_id, provider_metadata}
        )

  @spec consume_delivered_queue_items(GenServer.server(), String.t()) ::
          :ok | {:error, term()}
  def consume_delivered_queue_items(server, issue_identifier) when is_binary(issue_identifier),
    do: queue_api_call(server, {:consume_delivered_queue_items, issue_identifier})

  @spec restore_delivered_queue_items(GenServer.server(), String.t()) ::
          :ok | {:error, term()}
  def restore_delivered_queue_items(server, issue_identifier) when is_binary(issue_identifier),
    do: queue_api_call(server, {:restore_delivered_queue_items, issue_identifier})

  @spec fail_delivered_queue_items(GenServer.server(), String.t(), term()) ::
          :ok | {:error, term()}
  def fail_delivered_queue_items(server, issue_identifier, reason)
      when is_binary(issue_identifier),
      do: queue_api_call(server, {:fail_delivered_queue_items, issue_identifier, reason})

  defp control_api_call(server, request, timeout) do
    if GenServer.whereis(server) do
      GenServer.call(server, request, timeout)
    else
      {:error, :unavailable}
    end
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :unavailable}
  end

  # A timed-out claim can still mark an item delivered after its caller abandoned the receipt.
  defp queue_api_call(server, request, timeout \\ 5_000) do
    GenServer.call(server, request, timeout)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @spec enqueue_event_digest_item(State.t(), String.t(), list(), map(), keyword()) :: State.t()
  defdelegate enqueue_event_digest_item(state, identifier, events, summary_source, opts \\ []), to: Enqueue

  @spec enqueue_operator_message(State.t(), String.t(), String.t(), map(), :plain | :correlated) ::
          {{:ok, integer() | map()} | {:error, term()}, State.t()}
  defdelegate enqueue_operator_message(state, issue_identifier, body, payload, mode \\ :plain), to: Enqueue

  @spec enqueue_event_digest_call(State.t(), String.t(), map(), keyword()) ::
          {:reply, :ok, State.t()}
  defdelegate enqueue_event_digest_call(state, identifier, event, opts \\ []), to: Calls
  @spec enqueue_event_digest_batch_call(State.t(), String.t(), [map()]) :: {:reply, :ok, State.t()}
  defdelegate enqueue_event_digest_batch_call(state, identifier, events), to: Calls

  @spec send_operator_message_call(State.t(), String.t(), map()) ::
          {:reply, {:ok, integer()} | {:error, term()}, State.t()}
  defdelegate send_operator_message_call(state, issue_identifier, payload), to: Calls

  @spec send_correlated_operator_message_call(State.t(), String.t(), map()) ::
          {:reply, {:ok, map()} | {:error, term()}, State.t()}
  defdelegate send_correlated_operator_message_call(state, issue_identifier, payload), to: Calls
  @spec control_capabilities_call(State.t(), String.t()) :: {:reply, {:ok, map()}, State.t()}
  defdelegate control_capabilities_call(state, issue_identifier), to: Calls

  @spec claim_next_queue_item_call(State.t(), String.t()) ::
          {:reply, :empty | {:ok, map()}, State.t()}
  defdelegate claim_next_queue_item_call(state, issue_identifier), to: Calls

  @spec claim_next_checkpoint_queue_item_call(State.t(), String.t()) ::
          {:reply, :empty | {:ok, map()}, State.t()}
  defdelegate claim_next_checkpoint_queue_item_call(state, issue_identifier), to: Calls

  @spec claim_blocker_critical_events_digest_call(State.t(), String.t()) ::
          {:reply, :empty | {:ok, map()}, State.t()}
  defdelegate claim_blocker_critical_events_digest_call(state, issue_identifier), to: Calls

  @spec claim_next_operator_queue_item_call(State.t(), String.t()) ::
          {:reply, :empty | {:ok, map()}, State.t()}
  defdelegate claim_next_operator_queue_item_call(state, issue_identifier), to: Calls
  @spec claim_operator_response_call(State.t(), String.t(), String.t()) :: tuple()
  defdelegate claim_operator_response_call(state, identifier, command), to: Calls

  @spec operator_message_status_call(State.t(), integer()) ::
          {:reply, {:ok, Aiur.AgentQueueItem.status()} | {:error, :unknown_message}, State.t()}
  defdelegate operator_message_status_call(state, item_id), to: Calls

  @spec lookup_operator_message_call(State.t(), {:message_id | :action_id, String.t()}) ::
          {:reply, {:ok, Aiur.AgentQueueItem.t()} | {:error, :unknown_message}, State.t()}
  defdelegate lookup_operator_message_call(state, arg), to: Calls

  @spec lookup_operator_message_call(State.t(), {:message_id, String.t()}, %{
          target: term(),
          text: String.t()
        }) :: {:reply, {:ok, Aiur.AgentQueueItem.t()} | {:error, term()}, State.t()}
  defdelegate lookup_operator_message_call(state, lookup, map), to: Calls
  @spec mark_queue_item_consumed_call(State.t(), integer()) :: {:reply, :ok, State.t()}
  defdelegate mark_queue_item_consumed_call(state, item_id), to: Calls
  @spec restore_queue_item_pending_call(State.t(), integer()) :: {:reply, :ok, State.t()}
  defdelegate restore_queue_item_pending_call(state, item_id), to: Calls
  @spec mark_queue_item_failed_call(State.t(), integer(), term()) :: {:reply, :ok, State.t()}
  defdelegate mark_queue_item_failed_call(state, item_id, reason), to: Calls

  @spec acknowledge_queue_item_delivery_call(State.t(), integer(), map()) ::
          {:reply, :ok, State.t()}
  defdelegate acknowledge_queue_item_delivery_call(state, item_id, provider_metadata), to: Calls
  @spec consume_delivered_queue_items_call(State.t(), String.t()) :: {:reply, :ok, State.t()}
  defdelegate consume_delivered_queue_items_call(state, issue_identifier), to: Calls
  @spec restore_delivered_queue_items_call(State.t(), String.t()) :: {:reply, :ok, State.t()}
  defdelegate restore_delivered_queue_items_call(state, issue_identifier), to: Calls
  @spec fail_delivered_queue_items_call(State.t(), String.t(), term()) :: {:reply, :ok, State.t()}
  defdelegate fail_delivered_queue_items_call(state, issue_identifier, reason), to: Calls
  @spec coalesce_for_test(AgentQueueStore.t(), String.t()) :: {AgentQueueStore.t(), map() | nil}
  defdelegate coalesce_for_test(queue_store, issue_identifier), to: Calls

  @spec maybe_emit_agent_control_alert(atom(), atom(), map()) :: :ok
  defdelegate maybe_emit_agent_control_alert(previous_status, status, running_entry), to: ControlAlerts
  @spec maybe_emit_agent_control_alert(atom(), atom(), map(), atom() | String.t() | nil) :: :ok
  defdelegate maybe_emit_agent_control_alert(previous_status, status, running_entry, previous_pause_reason), to: ControlAlerts

  @spec send_running_control_message(State.t(), String.t(), (integer() -> term())) ::
          {:ok, integer()} | {:error, atom()}
  defdelegate send_running_control_message(state, issue_identifier, build_message), to: ControlAlerts

  @spec send_running_control_message(State.t(), String.t(), integer(), (integer() -> term())) ::
          {:ok, integer()} | {:error, atom()}
  defdelegate send_running_control_message(state, issue_identifier, request_id, build_message), to: ControlAlerts

  @spec notify_running_queue_update(State.t(), map(), term()) :: :ok
  defdelegate notify_running_queue_update(state, running_entry, item), to: DeliveryPolicy

  @doc false
  @spec comment_event_topic?(map()) :: boolean()
  defdelegate comment_event_topic?(event), to: DeliveryPolicy

  @spec queue_depth_for_issue(State.t(), String.t()) :: non_neg_integer()
  defdelegate queue_depth_for_issue(state, issue_identifier), to: Capabilities

  @spec pending_operator_messages_for_issue(State.t(), String.t()) :: [map()]
  defdelegate pending_operator_messages_for_issue(state, issue_identifier), to: Capabilities

  @spec issue_control_capabilities(State.t(), String.t()) :: map()
  defdelegate issue_control_capabilities(state, issue_identifier), to: Capabilities

  @doc false
  @spec issue_control_capabilities(State.t(), String.t(), map() | nil) :: map()
  defdelegate issue_control_capabilities(state, issue_identifier, running_entry), to: Capabilities
end
