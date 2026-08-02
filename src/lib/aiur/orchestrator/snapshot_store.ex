defmodule Aiur.Orchestrator.SnapshotStore do
  @moduledoc """
  Lock-free dashboard read model for fleet snapshots.

  Snapshot projection is coalesced in this process. Readers use
  `:persistent_term` directly, so neither a busy Orchestrator mailbox nor a
  SnapshotStore restart can remove the last-known-good fleet view.
  """

  use GenServer
  require Logger

  alias Aiur.Orchestrator.StatusReport
  alias AiurWeb.ObservabilityPubSub

  @cache_key __MODULE__
  @projection_delay_ms 50

  @type result ::
          {:current, map(), map()}
          | {:stale, map(), map()}
          | :snapshot_timeout
          | :orchestrator_unavailable

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Starts a new producer generation without replacing a retained snapshot.

  The generation token fences completion messages from a stopped orchestrator
  that shared this registered name.
  """
  @spec begin_generation(GenServer.server()) :: reference()
  def begin_generation(orchestrator) do
    generation = make_ref()
    :persistent_term.put(generation_key(orchestrator), generation)
    generation
  end

  @doc """
  Stores an already-projected snapshot. This is chiefly useful to lightweight
  Orchestrator implementations that do not own an `Aiur.Orchestrator.State`.
  """
  @spec publish(GenServer.server(), map()) :: :ok
  def publish(orchestrator, snapshot) when is_map(snapshot) do
    put_snapshot(orchestrator, active_generation(orchestrator), snapshot)
    :ok = ObservabilityPubSub.broadcast_update()
    :ok
  end

  @doc """
  Coalesces a state change for projection outside the Orchestrator process.
  """
  @spec publish_state(GenServer.server(), reference() | nil, Aiur.Orchestrator.State.t()) :: :ok
  def publish_state(orchestrator, generation, snapshot_input) do
    GenServer.cast(__MODULE__, {:publish_state, orchestrator, generation, snapshot_input})
    :ok
  end

  @doc """
  Reads the last published snapshot without sending a message to the
  Orchestrator. A cache is retained across Orchestrator restarts; its metadata
  makes that degraded state explicit instead of blanking the dashboard.
  """
  @spec read(GenServer.server(), timeout()) :: result()
  def read(orchestrator, timeout) do
    case cached_snapshot(orchestrator) do
      nil ->
        no_snapshot_result(orchestrator)

      %{snapshot: snapshot, observed_at: observed_at, observed_at_ms: observed_at_ms} = cached ->
        metadata = metadata(orchestrator, cached, observed_at, observed_at_ms, timeout)

        case metadata.status do
          :stale ->
            maybe_log_timeout(orchestrator, metadata)
            {:stale, snapshot, metadata}

          :current ->
            {:current, snapshot, metadata}
        end
    end
  end

  @impl true
  def init(_opts), do: {:ok, %{pending: %{}, task_ref: nil, monitor_ref: nil, timer_ref: nil}}

  @impl true
  def handle_cast({:publish_state, orchestrator, generation, snapshot_input}, store) do
    if generation == active_generation(orchestrator) do
      pending = Map.put(store.pending, orchestrator, {generation, snapshot_input})
      {:noreply, store |> Map.put(:pending, pending) |> schedule_projection()}
    else
      {:noreply, store}
    end
  end

  @impl true
  def handle_info(:project_pending, %{task_ref: nil} = store) do
    {:noreply, store |> Map.put(:timer_ref, nil) |> start_projection()}
  end

  @impl true
  def handle_info({:snapshot_built, ref, orchestrator, generation, {:ok, snapshot}}, %{task_ref: ref} = store) do
    if generation == active_generation(orchestrator) do
      put_snapshot(orchestrator, generation, snapshot)
      :ok = ObservabilityPubSub.broadcast_update()
    end

    {:noreply, store |> clear_task() |> schedule_projection()}
  end

  def handle_info({:snapshot_built, ref, _orchestrator, _generation, {:error, error}}, %{task_ref: ref} = store) do
    Logger.debug("Skipping incomplete dashboard snapshot: #{Exception.message(error)}")
    {:noreply, store |> clear_task() |> schedule_projection()}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{monitor_ref: ref} = store) do
    if reason != :normal, do: Logger.debug("Dashboard snapshot projection exited: #{inspect(reason)}")
    {:noreply, store |> clear_task() |> schedule_projection()}
  end

  def handle_info(_message, store), do: {:noreply, store}

  defp start_projection(%{task_ref: nil, pending: pending} = store) when map_size(pending) > 0 do
    [{orchestrator, {generation, snapshot_input}}] = Enum.take(pending, 1)
    pending = Map.delete(pending, orchestrator)
    store_pid = self()
    task_ref = make_ref()

    pid =
      spawn(fn ->
        result =
          try do
            {:ok, StatusReport.snapshot_payload(snapshot_input)}
          rescue
            error -> {:error, error}
          end

        send(store_pid, {:snapshot_built, task_ref, orchestrator, generation, result})
      end)

    %{store | pending: pending, task_ref: task_ref, monitor_ref: Process.monitor(pid)}
  end

  defp start_projection(store), do: store

  defp clear_task(store), do: %{store | task_ref: nil, monitor_ref: nil}

  defp schedule_projection(%{task_ref: nil, timer_ref: nil, pending: pending} = store) when map_size(pending) > 0 do
    %{store | timer_ref: Process.send_after(self(), :project_pending, @projection_delay_ms)}
  end

  defp schedule_projection(store), do: store

  defp put_snapshot(orchestrator, generation, snapshot) do
    :persistent_term.put(
      {@cache_key, orchestrator},
      %{
        generation: generation,
        snapshot: snapshot,
        observed_at: DateTime.utc_now(),
        observed_at_ms: System.monotonic_time(:millisecond)
      }
    )
  end

  defp cached_snapshot(orchestrator), do: :persistent_term.get({@cache_key, orchestrator}, nil)

  defp no_snapshot_result(orchestrator) do
    case live_pid(orchestrator) do
      nil ->
        :orchestrator_unavailable

      pid ->
        maybe_log_initial_timeout(orchestrator, mailbox_depth(pid))
        :snapshot_timeout
    end
  end

  defp metadata(orchestrator, cached, observed_at, observed_at_ms, timeout) do
    age_ms = max(System.monotonic_time(:millisecond) - observed_at_ms, 0)
    pid = live_pid(orchestrator)
    mailbox_depth = mailbox_depth(pid)

    reason =
      cond do
        is_nil(pid) -> :orchestrator_unavailable
        Map.get(cached, :generation) != active_generation(orchestrator) -> :orchestrator_unavailable
        timeout_elapsed_behind_backlog?(age_ms, timeout, mailbox_depth) -> :snapshot_timeout
        true -> nil
      end

    %{
      status: if(reason, do: :stale, else: :current),
      reason: reason,
      observed_at: DateTime.to_iso8601(observed_at),
      age_ms: age_ms,
      age_seconds: div(age_ms, 1_000),
      orchestrator_mailbox_depth: mailbox_depth
    }
  end

  defp timeout_elapsed_behind_backlog?(age_ms, timeout, mailbox_depth) do
    is_integer(timeout) and timeout >= 0 and age_ms >= timeout and is_integer(mailbox_depth) and
      mailbox_depth > 0
  end

  defp maybe_log_timeout(orchestrator, %{reason: :snapshot_timeout} = metadata) do
    warning_key = {@cache_key, :last_timeout_log, orchestrator}

    if :persistent_term.get(warning_key, nil) != metadata.observed_at do
      :persistent_term.put(warning_key, metadata.observed_at)

      Logger.warning(
        "Dashboard snapshot timed out; serving last-known-good snapshot " <>
          "(orchestrator_mailbox_depth=#{metadata.orchestrator_mailbox_depth}, age_ms=#{metadata.age_ms})"
      )
    end
  end

  defp maybe_log_timeout(_orchestrator, _metadata), do: :ok

  defp maybe_log_initial_timeout(orchestrator, mailbox_depth) do
    warning_key = {@cache_key, :last_timeout_log, orchestrator}

    if :persistent_term.get(warning_key, nil) != :before_first_snapshot do
      :persistent_term.put(warning_key, :before_first_snapshot)

      Logger.warning(
        "Dashboard snapshot timed out before the first snapshot was published " <>
          "(orchestrator_mailbox_depth=#{mailbox_depth})"
      )
    end
  end

  defp live_pid(orchestrator) do
    GenServer.whereis(orchestrator)
  catch
    :exit, _reason -> nil
  end

  defp mailbox_depth(pid) when is_pid(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, depth} -> depth
      _ -> :unknown
    end
  end

  defp mailbox_depth(_pid), do: :unknown

  defp generation_key(orchestrator), do: {@cache_key, :generation, orchestrator}
  defp active_generation(orchestrator), do: :persistent_term.get(generation_key(orchestrator), nil)
end
