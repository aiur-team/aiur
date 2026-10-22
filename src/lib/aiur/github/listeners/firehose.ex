defmodule Aiur.GitHub.Listeners.Firehose do
  @moduledoc "Owns the repository event cursor and its truncation and persistence latches."
  use GenServer
  require Logger

  alias Aiur.Alerts
  alias Aiur.Events.GithubFirehose
  alias Aiur.GitHub.Listeners.Firehose.Window

  @type t :: %__MODULE__{}
  defstruct events_etag: nil,
            events_last_id: nil,
            firehose_partial_streak: 0,
            firehose_truncation_alert_active: false,
            firehose_truncation_alert_resolution_emitted: false,
            recent_merge_persistence_failures: 0,
            pending_poll: nil,
            poll_queue: :queue.new(),
            outcome: %{connectivity: [], poll_interval: nil}

  @recent_merge_persistence_retry_limit 3

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, Keyword.take(opts, [:name]))

  @impl true
  def init(:ok) do
    Process.flag(:trap_exit, true)
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    stop_poll(state.pending_poll)
    if state.pending_poll, do: GenServer.reply(state.pending_poll.from, {:error, :firehose_reset})
    for {from, _opts} <- :queue.to_list(state.poll_queue), do: GenServer.reply(from, {:error, :firehose_reset})
    {:reply, :ok, %__MODULE__{}}
  end

  def handle_call({:poll, opts}, from, %{pending_poll: nil} = state), do: {:noreply, start_poll(state, from, opts)}

  def handle_call({:poll, opts}, from, state),
    do: {:noreply, %{state | poll_queue: :queue.in({from, opts}, state.poll_queue)}}

  @impl true
  def handle_info({ref, result}, %{pending_poll: %{task: %{ref: ref}} = poll} = state) do
    Process.demonitor(ref, [:flush])
    Process.demonitor(poll.caller_ref, [:flush])
    next = apply_result(%{state | pending_poll: nil}, result, poll.opts)
    GenServer.reply(poll.from, next.outcome)
    {:noreply, next_poll(next)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{pending_poll: %{task: %{ref: ref}} = poll} = state) do
    Process.demonitor(poll.caller_ref, [:flush])
    GenServer.reply(poll.from, {:error, {:tracker_task_exit, reason}})
    {:noreply, next_poll(%{state | pending_poll: nil})}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{pending_poll: %{caller_ref: ref} = poll} = state) do
    stop_poll(poll)
    {:noreply, next_poll(%{state | pending_poll: nil})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: stop_poll(state.pending_poll)

  # Keep cancellation beside cursor application so reset cannot accept a late worker result.
  defp start_poll(state, from, opts) do
    poll_opts = opts |> Keyword.put_new(:etag, state.events_etag) |> Keyword.put_new(:last_event_id, state.events_last_id)
    caller_ref = Process.monitor(elem(from, 0))
    task = Task.Supervisor.async_nolink(Aiur.TaskSupervisor, fn -> GithubFirehose.poll(poll_opts) end)
    %{state | pending_poll: %{task: task, from: from, caller_ref: caller_ref, opts: opts}, outcome: %{connectivity: [], poll_interval: nil}}
  end

  defp next_poll(state) do
    case :queue.out(state.poll_queue) do
      {{:value, {from, opts}}, rest} -> start_poll(%{state | poll_queue: rest}, from, opts)
      {:empty, _} -> state
    end
  end

  defp stop_poll(nil), do: :ok

  defp stop_poll(poll) do
    Process.demonitor(poll.caller_ref, [:flush])
    Task.shutdown(poll.task, :brutal_kill)
    :ok
  end

  defp apply_result(state, {:ok, %{etag: etag, last_event_id: last_event_id} = result}, opts) do
    state
    |> note_connectivity(:firehose, :ok)
    |> note_poll_interval(Map.get(result, :poll_interval))
    |> note_recent_merge_persistence_success(Map.get(result, :recent_merge_persistence))
    |> Window.note_firehose_window(result, opts)
    |> Map.merge(%{events_etag: etag, events_last_id: last_event_id})
  end

  defp apply_result(state, {:error, {:recent_merge_persistence, reason, cursor}}, opts),
    do: note_recent_merge_persistence_failure(state, reason, cursor, opts)

  defp apply_result(state, {:error, reason}, _opts), do: note_connectivity(state, :firehose, {:error, reason})

  defp note_connectivity(state, source, result) do
    %{state | outcome: %{state.outcome | connectivity: state.outcome.connectivity ++ [{source, result}]}}
  end

  defp note_poll_interval(state, interval), do: %{state | outcome: %{state.outcome | poll_interval: interval}}

  defp note_recent_merge_persistence_success(state, :ok) do
    %{state | recent_merge_persistence_failures: 0} |> note_connectivity(:recent_merge_store, :ok)
  end

  defp note_recent_merge_persistence_success(state, _status), do: state

  defp note_recent_merge_persistence_failure(state, reason, cursor, opts) do
    failures = recent_merge_persistence_failure_count(state) + 1
    retry_limit = recent_merge_persistence_retry_limit(opts)
    advance? = failures >= retry_limit

    Logger.warning("GithubFirehose local outcome persistence failed; attempt=#{failures} advance=#{advance?} reason=#{inspect(reason)}")

    state =
      %{state | recent_merge_persistence_failures: failures}
      |> note_connectivity(:firehose, :ok)
      |> note_poll_interval(Map.get(cursor, :poll_interval))
      |> note_connectivity(:recent_merge_store, {:error, {:recent_merge_persistence, reason}})
      |> maybe_alert_recent_merge_persistence(reason, retry_limit, opts)

    if advance? do
      %{
        state
        | events_etag: Map.get(cursor, :etag),
          events_last_id: Map.get(cursor, :last_event_id)
      }
    else
      state
    end
  end

  defp recent_merge_persistence_failure_count(state) do
    state.recent_merge_persistence_failures
  end

  defp recent_merge_persistence_retry_limit(opts) do
    case Keyword.get(opts, :recent_merge_persistence_retry_limit, @recent_merge_persistence_retry_limit) do
      value when is_integer(value) and value > 0 -> value
      _other -> @recent_merge_persistence_retry_limit
    end
  end

  defp maybe_alert_recent_merge_persistence(state, reason, limit, opts) do
    if recent_merge_persistence_failure_count(state) == limit do
      emit_recent_merge_persistence_alert(state, reason, opts)
    else
      state
    end
  end

  defp emit_recent_merge_persistence_alert(state, reason, opts) do
    failures = recent_merge_persistence_failure_count(state)

    message =
      "Recent repository merge audit remains read-only or unwritable after " <>
        "#{failures} attempts (#{inspect(reason)}). " <>
        "GitHub event delivery is continuing without durable outcome records until storage recovers."

    alert_fun = Keyword.get(opts, :recent_merge_alert_fun, &Alerts.emit_custom/3)

    _ =
      alert_fun.("recent_merge_store.persistence_failed", message,
        reason: message,
        needs_attention: true,
        severity: "warning"
      )

    state
  rescue
    error ->
      Logger.warning("GithubFirehose local outcome persistence alert failed; reason=#{Exception.message(error)}")
      state
  catch
    kind, reason ->
      Logger.warning("GithubFirehose local outcome persistence alert failed; reason=#{inspect({kind, reason})}")
      state
  end
end
