defmodule Aiur.Orchestrator.Client do
  @moduledoc "Client forwarding for the Orchestrator RPC facade, with the original server defaults."
  alias Aiur.Orchestrator.{GlobalPause, Interrupts, Lifecycle, PauseResume, PriorityControl, PushRouting, Slots, SnapshotStore, StatusReport, TelemetryEvents}

  alias Aiur.Orchestrator.OperatorMessages, as: OM
  alias Aiur.Orchestrator.RemoteControlMode, as: RC

  # Public RPC facade; implementations live with their owning submodules.
  @spec request_refresh() :: map() | :unavailable
  def request_refresh, do: Lifecycle.request_refresh_api()
  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server), do: Lifecycle.request_refresh_api(server)
  @spec note_queued_demand([String.t()]) :: map() | :unavailable
  def note_queued_demand(identifiers), do: note_queued_demand(Aiur.Orchestrator, identifiers)
  @spec note_queued_demand(GenServer.server(), [String.t()]) :: map() | :unavailable
  def note_queued_demand(server, identifiers) when is_list(identifiers),
    do: Lifecycle.note_queued_demand_api(server, identifiers)

  @spec send_operator_message(String.t() | Aiur.TrackerIdentity.t(), map()) :: {:ok, integer()} | {:error, term()}
  def send_operator_message(identifier, payload),
    do: OM.send_operator_message(identifier, payload)

  @spec send_operator_message(GenServer.server(), String.t() | Aiur.TrackerIdentity.t(), map()) ::
          {:ok, integer()} | {:error, term()}
  def send_operator_message(server, identifier, payload),
    do: OM.send_operator_message(server, identifier, payload)

  @spec send_correlated_operator_message(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def send_correlated_operator_message(identifier, payload),
    do: OM.send_correlated_operator_message(identifier, payload)

  @spec send_correlated_operator_message(GenServer.server(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def send_correlated_operator_message(server, identifier, payload),
    do: OM.send_correlated_operator_message(server, identifier, payload)

  @spec pause_agent(String.t() | Aiur.TrackerIdentity.t()) :: {:ok, integer()} | {:error, term()}
  def pause_agent(identifier), do: PauseResume.pause_agent(identifier)
  @spec pause_agent(GenServer.server(), String.t() | Aiur.TrackerIdentity.t()) :: {:ok, integer()} | {:error, term()}
  def pause_agent(server, identifier), do: PauseResume.pause_agent(server, identifier)
  @spec request_control(String.t(), :pause | :resume, pos_integer()) :: {:ok, pos_integer()} | {:error, term()}
  def request_control(identifier, action, request_id), do: PauseResume.request_control(identifier, action, request_id)
  @spec request_control(GenServer.server(), String.t(), :pause | :resume, pos_integer()) :: {:ok, pos_integer()} | {:error, term()}
  def request_control(server, identifier, action, request_id), do: PauseResume.request_control(server, identifier, action, request_id)
  @spec mark_sleeping(String.t()) :: :ok
  def mark_sleeping(identifier), do: PushRouting.mark_sleeping(identifier)
  @spec mark_sleeping(GenServer.server(), String.t()) :: :ok
  def mark_sleeping(server, identifier), do: PushRouting.mark_sleeping(server, identifier)
  @spec interrupt_agent(String.t()) :: :ok | {:error, term()}
  def interrupt_agent(identifier), do: Interrupts.interrupt_agent(identifier)
  @spec interrupt_agent(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def interrupt_agent(server, identifier), do: Interrupts.interrupt_agent(server, identifier)

  @spec pane_interrupt(String.t()) ::
          {:ok, :interrupted | :pause_requested | :paused | :close_pane | :send_interrupt} | {:error, term()}
  def pane_interrupt(identifier), do: Interrupts.pane_interrupt(identifier)

  @spec pane_interrupt(GenServer.server(), String.t()) ::
          {:ok, :interrupted | :pause_requested | :paused | :close_pane | :send_interrupt} | {:error, term()}
  def pane_interrupt(server, identifier), do: Interrupts.pane_interrupt(server, identifier)

  @spec pane_interrupt_by_pane_id(String.t()) ::
          {:ok, :interrupted | :pause_requested | :paused | :close_pane | :send_interrupt} | {:error, term()}
  def pane_interrupt_by_pane_id(pane_id), do: Interrupts.pane_interrupt_by_pane_id(pane_id)

  @spec pane_interrupt_by_pane_id(GenServer.server(), String.t()) ::
          {:ok, :interrupted | :pause_requested | :paused | :close_pane | :send_interrupt} | {:error, term()}
  def pane_interrupt_by_pane_id(server, pane_id),
    do: Interrupts.pane_interrupt_by_pane_id(server, pane_id)

  @spec resume_agent(String.t()) :: {:ok, :resumed | :started} | {:error, term()}
  def resume_agent(identifier), do: PauseResume.resume_agent(identifier)

  @spec resume_agent(GenServer.server(), String.t()) ::
          {:ok, :resumed | :started} | {:error, term()}
  def resume_agent(server, identifier), do: PauseResume.resume_agent(server, identifier)

  @spec resume_agent_with_receipt(String.t()) ::
          {:ok, :resumed | :started | :reactivated | {:resumed, pos_integer()}} | {:error, term()}
  def resume_agent_with_receipt(identifier), do: PauseResume.resume_agent_with_receipt(identifier)

  @spec resume_agent_with_receipt(GenServer.server(), String.t()) ::
          {:ok, :resumed | :started | :reactivated | {:resumed, pos_integer()}} | {:error, term()}
  def resume_agent_with_receipt(server, identifier), do: PauseResume.resume_agent_with_receipt(server, identifier)

  @spec prioritize_agent(String.t()) :: {:ok, :prioritized | :already_prioritized} | {:error, term()}
  def prioritize_agent(identifier), do: PriorityControl.prioritize_agent(identifier)
  @spec prioritize_agent(GenServer.server(), String.t()) :: {:ok, :prioritized | :already_prioritized} | {:error, term()}
  def prioritize_agent(server, identifier), do: PriorityControl.prioritize_agent(server, identifier)

  @spec deprioritize_agent(String.t()) :: {:ok, :deprioritized | :already_deprioritized} | {:error, term()}
  def deprioritize_agent(identifier), do: PriorityControl.deprioritize_agent(identifier)
  @spec deprioritize_agent(GenServer.server(), String.t()) :: {:ok, :deprioritized | :already_deprioritized} | {:error, term()}
  def deprioritize_agent(server, identifier), do: PriorityControl.deprioritize_agent(server, identifier)

  @spec control_lifecycle(String.t()) :: {:ok, map()} | {:error, term()}
  def control_lifecycle(identifier), do: PauseResume.control_lifecycle(identifier)
  @spec control_lifecycle(GenServer.server(), String.t()) :: {:ok, map()} | {:error, term()}
  def control_lifecycle(server, identifier), do: PauseResume.control_lifecycle(server, identifier)

  @doc """
  Clears a ticket's lifetime dispatch latch (in-memory + durable store) so a
  latched ticket returns to dispatchable. The supported operator exit from
  the #1453 latch — `aiurdev reset-budget <id>` routes here.
  """
  @spec reset_dispatch_budget(String.t()) :: {:ok, :reset} | {:error, term()}
  def reset_dispatch_budget(identifier), do: PauseResume.reset_dispatch_budget(identifier)

  @spec reset_dispatch_budget(GenServer.server(), String.t()) :: {:ok, :reset} | {:error, term()}
  def reset_dispatch_budget(server, identifier),
    do: PauseResume.reset_dispatch_budget(server, identifier)

  @spec max_concurrent_agents() :: map() | :unavailable
  def max_concurrent_agents, do: Slots.max_concurrent_agents()
  @spec max_concurrent_agents(GenServer.server()) :: map() | :unavailable
  def max_concurrent_agents(server), do: Slots.max_concurrent_agents(server)
  @spec adjust_max_concurrent_agents(integer()) :: {:ok, map()} | {:error, term()}
  def adjust_max_concurrent_agents(delta), do: Slots.adjust_max_concurrent_agents(delta)

  @spec adjust_max_concurrent_agents(GenServer.server(), integer()) ::
          {:ok, map()} | {:error, term()}
  def adjust_max_concurrent_agents(server, delta),
    do: Slots.adjust_max_concurrent_agents(server, delta)

  @spec set_max_concurrent_agents(pos_integer()) :: {:ok, map()} | {:error, term()}
  def set_max_concurrent_agents(next), do: Slots.set_max_concurrent_agents(next)

  @spec set_max_concurrent_agents(GenServer.server(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def set_max_concurrent_agents(server, next),
    do: Slots.set_max_concurrent_agents(server, next)

  @spec globally_paused?() :: {:ok, boolean()} | {:error, :orchestrator_unavailable}
  def globally_paused?, do: GlobalPause.globally_paused?()

  @spec global_pause_status() :: {:ok, map()} | {:error, :timeout | :orchestrator_unavailable}
  def global_pause_status, do: GlobalPause.global_pause_status()

  @spec global_pause_status(GenServer.server(), pos_integer()) ::
          {:ok, map()} | {:error, :timeout | :orchestrator_unavailable}
  def global_pause_status(server, timeout_ms), do: GlobalPause.global_pause_status(server, timeout_ms)

  @spec set_global_pause(boolean()) :: {:ok, map()} | {:error, term()}
  def set_global_pause(on?) when is_boolean(on?), do: GlobalPause.set_global_pause(on?)

  @spec set_global_pause(boolean(), String.t()) :: {:ok, map()} | {:error, term()}
  def set_global_pause(on?, source) when is_boolean(on?) and is_binary(source), do: GlobalPause.set_global_pause(Aiur.Orchestrator, on?, source)

  @spec control_capabilities(String.t()) :: {:ok, map()} | {:error, term()}
  def control_capabilities(identifier), do: OM.control_capabilities(identifier)
  @spec control_capabilities(GenServer.server(), String.t()) :: {:ok, map()} | {:error, term()}
  def control_capabilities(server, identifier),
    do: OM.control_capabilities(server, identifier)

  @spec set_remote_control(String.t(), boolean()) :: {:ok, :on | :off} | {:error, term()}
  def set_remote_control(identifier, on?), do: RC.set_remote_control(identifier, on?)

  @spec set_remote_control(GenServer.server(), String.t(), boolean()) ::
          {:ok, :on | :off} | {:error, term()}
  def set_remote_control(server, identifier, on?),
    do: RC.set_remote_control(server, identifier, on?)

  @spec ensure_remote_control_trust(Path.t()) :: :ok | {:error, term()}
  def ensure_remote_control_trust(workspace), do: RC.ensure_remote_control_trust(workspace)
  @spec ensure_remote_control_trust(GenServer.server(), Path.t()) :: :ok | {:error, term()}
  def ensure_remote_control_trust(server, workspace),
    do: RC.ensure_remote_control_trust(server, workspace)

  @spec operator_message_status(GenServer.server(), integer(), timeout()) ::
          {:ok, Aiur.AgentQueueItem.status()} | {:error, term()}
  def operator_message_status(server \\ Aiur.Orchestrator, item_id, timeout \\ 5_000),
    do: OM.operator_message_status(server, item_id, timeout)

  @spec claim_next_queue_item(GenServer.server(), String.t()) ::
          {:ok, map()} | :empty | {:error, term()}
  def claim_next_queue_item(server, identifier),
    do: OM.claim_next_queue_item(server, identifier)

  @spec claim_next_checkpoint_queue_item(GenServer.server(), String.t()) ::
          {:ok, map()} | :empty | {:error, term()}
  def claim_next_checkpoint_queue_item(server, identifier),
    do: OM.claim_next_checkpoint_queue_item(server, identifier)

  @spec claim_blocker_critical_events_digest(GenServer.server(), String.t()) ::
          {:ok, map()} | :empty | {:error, term()}
  def claim_blocker_critical_events_digest(server, identifier),
    do: OM.claim_blocker_critical_events_digest(server, identifier)

  @spec claim_next_operator_queue_item(GenServer.server(), String.t()) ::
          {:ok, map()} | :empty | {:error, term()}
  def claim_next_operator_queue_item(server, identifier),
    do: OM.claim_next_operator_queue_item(server, identifier)

  @spec claim_operator_response(GenServer.server(), String.t(), String.t()) :: {:ok, map()} | :empty | {:error, term()}
  def claim_operator_response(server, identifier, command), do: OM.claim_operator_response(server, identifier, command)

  @spec mark_queue_item_consumed(GenServer.server(), integer()) :: :ok | {:error, term()}
  def mark_queue_item_consumed(server, item_id),
    do: OM.mark_queue_item_consumed(server, item_id)

  @spec restore_queue_item_pending(GenServer.server(), integer()) :: :ok | {:error, term()}
  def restore_queue_item_pending(server, item_id),
    do: OM.restore_queue_item_pending(server, item_id)

  @spec mark_queue_item_failed(GenServer.server(), integer(), term()) :: :ok | {:error, term()}
  def mark_queue_item_failed(server, item_id, reason),
    do: OM.mark_queue_item_failed(server, item_id, reason)

  @spec acknowledge_queue_item_delivery(GenServer.server(), integer(), map()) ::
          :ok | {:error, term()}
  def acknowledge_queue_item_delivery(server, item_id, provider_metadata),
    do: OM.acknowledge_queue_item_delivery(server, item_id, provider_metadata)

  @spec consume_delivered_queue_items(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def consume_delivered_queue_items(server, identifier),
    do: OM.consume_delivered_queue_items(server, identifier)

  @spec restore_delivered_queue_items(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def restore_delivered_queue_items(server, identifier),
    do: OM.restore_delivered_queue_items(server, identifier)

  @spec fail_delivered_queue_items(GenServer.server(), String.t(), term()) :: :ok | {:error, term()}
  def fail_delivered_queue_items(server, identifier, reason),
    do: OM.fail_delivered_queue_items(server, identifier, reason)

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: StatusReport.snapshot_api()
  @spec list_active_identifiers(GenServer.server(), timeout()) :: [String.t()]
  def list_active_identifiers(server \\ Aiur.Orchestrator, timeout \\ 1_000),
    do: StatusReport.list_active_identifiers_api(server, timeout)

  @spec list_running_active_identifiers(GenServer.server(), timeout()) :: [String.t()]
  def list_running_active_identifiers(server \\ Aiur.Orchestrator, timeout \\ 1_000),
    do: StatusReport.list_running_active_identifiers_api(server, timeout)

  @type poll_status :: %{
          checking?: boolean(),
          next_poll_in_ms: integer() | nil,
          effective_interval_ms: integer() | nil,
          idle_backoff: %{active?: boolean(), factor: float()} | nil
        }

  @spec poll_status() :: poll_status() | :unavailable
  def poll_status, do: StatusReport.poll_status_api()

  @spec poll_status(GenServer.server(), timeout()) :: poll_status() | :unavailable
  def poll_status(server, timeout), do: StatusReport.poll_status_api(server, timeout)
  @spec status() :: [map()] | :timeout | :unavailable
  def status, do: StatusReport.status_api()
  @spec status(GenServer.server(), timeout()) :: [map()] | :timeout | :unavailable
  def status(server, timeout), do: StatusReport.status_api(server, timeout)
  @spec status_with_capacity(GenServer.server(), timeout()) :: {[map()], map()} | :timeout | :unavailable
  def status_with_capacity(server, timeout), do: StatusReport.status_with_capacity_api(server, timeout)
  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout), do: StatusReport.snapshot_api(server, timeout)

  @doc """
  Reads the published dashboard snapshot without querying the Orchestrator;
  before first publication it returns unavailable. See `SnapshotStore.read/2`.
  """
  @spec dashboard_snapshot(GenServer.server(), timeout()) :: SnapshotStore.result()
  def dashboard_snapshot(server \\ Aiur.Orchestrator, timeout \\ 15_000), do: SnapshotStore.read(server, timeout) |> TelemetryEvents.binding_snapshot()

  @doc """
  Reads the fleet view for a control query (`status`, `agents`, `watch`) from
  the read model, never from this process's mailbox. See
  `Aiur.Orchestrator.StatusReport.fleet_view/2`.
  """
  @spec fleet_view(GenServer.server(), timeout(), keyword()) :: {:ok, map(), map()} | {:error, :timeout | :unavailable}
  def fleet_view(server \\ Aiur.Orchestrator, timeout, opts \\ []), do: StatusReport.fleet_view(server, timeout, opts)
end
