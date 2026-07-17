defmodule Aiur.CoordinationTasks do
  @moduledoc """
  Bounded, keyed admission for best-effort coordination side effects.

  Operations for one key retain admission order while independent keys may run
  concurrently. Runnable keys are scheduled in FIFO order so a busy key cannot
  starve other accepted work. Admission is synchronous and bounded so callers
  never report acceptance unless this process owns the work.
  """

  use GenServer

  require Logger

  alias Aiur.SecretRedactor

  @default_admission_timeout_ms 100
  @default_operation_timeout_ms 30_000
  @default_max_pending 1_000
  @default_max_concurrency 16
  @task_start_retry_ms 100
  @max_failure_chars 500

  @type key :: term()
  @type admission_result ::
          :pending
          | {:error, :coordination_overloaded | :coordination_unavailable | :coordination_indeterminate}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec enqueue(key(), (-> term()), GenServer.server(), keyword(), timeout()) :: admission_result()
  def enqueue(
        key,
        operation,
        server \\ __MODULE__,
        opts \\ [],
        admission_timeout \\ @default_admission_timeout_ms
      )
      when is_function(operation, 0) do
    operation_timeout = Keyword.get(opts, :operation_timeout, :default)
    log_context = log_context(opts)
    deadline = admission_deadline(admission_timeout)

    GenServer.call(
      server,
      {:enqueue, key, operation, operation_timeout, deadline, log_context},
      admission_timeout
    )
  catch
    :exit, {:timeout, _reason} -> {:error, :coordination_indeterminate}
    :exit, reason -> coordination_exit(reason)
  end

  @doc """
  Runs an operation through the same keyed lane and returns its terminal result.

  This is for mutations whose caller-visible result is part of the tool contract.
  The default infinite call timeout leaves operation-specific timeouts to the
  downstream service instead of releasing the key while a mutation may still land.
  """
  @spec run(key(), (-> term()), GenServer.server(), keyword(), timeout()) :: term()
  def run(
        key,
        operation,
        server \\ __MODULE__,
        opts \\ [],
        call_timeout \\ :infinity
      )
      when is_function(operation, 0) do
    operation_timeout = Keyword.get(opts, :operation_timeout, :default)
    GenServer.call(server, {:run, key, operation, operation_timeout, log_context(opts)}, call_timeout)
  catch
    :exit, {:timeout, _reason} -> {:error, :coordination_indeterminate}
    :exit, reason -> coordination_exit(reason)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    max_pending = Keyword.get(opts, :max_pending, @default_max_pending)

    {:ok,
     %{
       active: %{},
       queues: %{},
       runnable_keys: :queue.new(),
       runnable_key_set: MapSet.new(),
       pending: 0,
       operation_timeout_ms: Keyword.get(opts, :operation_timeout_ms, @default_operation_timeout_ms),
       max_pending: max_pending,
       max_pending_per_key: Keyword.get(opts, :max_pending_per_key, default_per_key_limit(max_pending)),
       max_concurrency: Keyword.get(opts, :max_concurrency, @default_max_concurrency),
       task_starter: Keyword.get(opts, :task_starter, &start_task/1)
     }}
  end

  @impl true
  def handle_call({:enqueue, key, operation, timeout, deadline, log_context}, _from, state) do
    cond do
      not admission_available?(state, key) ->
        {:reply, {:error, :coordination_overloaded}, state}

      admission_expired?(deadline) ->
        {:reply, {:error, :coordination_unavailable}, state}

      true ->
        entry = entry(operation, timeout, nil, log_context, state)
        {:reply, :pending, queue_entry(key, entry, state), {:continue, :dispatch}}
    end
  end

  def handle_call({:run, key, operation, timeout, log_context}, from, state) do
    if admission_available?(state, key) do
      entry = entry(operation, timeout, from, log_context, state)
      {:noreply, queue_entry(key, entry, state), {:continue, :dispatch}}
    else
      {:reply, {:error, :coordination_overloaded}, state}
    end
  end

  @impl true
  def handle_continue(:dispatch, state), do: {:noreply, dispatch(state)}

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    case active_by_ref(state.active, ref) do
      {key, task} ->
        log_failure(key, task, result)
        complete(key, task, result, state)

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case active_by_ref(state.active, ref) do
      {key, task} ->
        result = {:error, {:coordination_task_exit, reason}}
        log_failure(key, task, result)
        complete(key, task, result, state)

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:coordination_timeout, ref}, state) do
    case active_by_ref(state.active, ref) do
      {key, task} ->
        result = {:error, :coordination_timeout}
        log_failure(key, task, result)
        Process.unlink(task.pid)
        _ = Task.Supervisor.terminate_child(Aiur.TaskSupervisor, task.pid)
        complete(key, task, result, state)

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(:retry_dispatch, state), do: {:noreply, dispatch(state)}

  def handle_info(_message, state), do: {:noreply, state}

  defp complete(key, task, result, state) do
    Process.demonitor(task.ref, [:flush])
    cancel_timer(task.timer, task.ref)
    reply(task.reply_to, result)

    state =
      state
      |> Map.put(:active, Map.delete(state.active, key))
      |> make_runnable(key)

    {:noreply, dispatch(state)}
  end

  defp reply(nil, _result), do: :ok
  defp reply(from, result), do: GenServer.reply(from, result)

  defp cancel_timer(nil, _ref), do: :ok

  defp cancel_timer(timer, ref) do
    case Process.cancel_timer(timer) do
      false ->
        receive do
          {:coordination_timeout, ^ref} -> :ok
        after
          0 -> :ok
        end

      _remaining ->
        :ok
    end
  end

  defp dispatch(state) when map_size(state.active) >= state.max_concurrency, do: state

  defp dispatch(state) do
    case pop_runnable(state) do
      {key, state} ->
        queue = Map.fetch!(state.queues, key)
        {{:value, entry}, queue} = :queue.out(queue)

        case safely_start_task(state.task_starter, entry) do
          {:ok, task} -> activate_task(state, key, queue, entry, task)
          {:error, reason} -> retry_task_start(state, key, reason)
        end

      :empty ->
        state
    end
  end

  defp activate_task(state, key, queue, entry, task) do
    task =
      task
      |> Map.put(:timer, schedule_timeout(task.ref, entry.timeout))
      |> Map.put(:operation_timeout, entry.timeout)
      |> Map.put(:log_context, entry.log_context)
      |> Map.put(:reply_to, entry.reply_to)

    queues = if :queue.is_empty(queue), do: Map.delete(state.queues, key), else: Map.put(state.queues, key, queue)

    state
    |> Map.put(:queues, queues)
    |> Map.put(:pending, state.pending - 1)
    |> Map.put(:active, Map.put(state.active, key, task))
    |> dispatch()
  end

  defp retry_task_start(state, key, reason) do
    Logger.warning("coordination task start failed failure=#{safe_detail(reason)}")
    Process.send_after(self(), :retry_dispatch, @task_start_retry_ms)
    make_runnable(state, key)
  end

  defp pop_runnable(state) do
    case :queue.out(state.runnable_keys) do
      {{:value, key}, runnable_keys} ->
        state = %{
          state
          | runnable_keys: runnable_keys,
            runnable_key_set: MapSet.delete(state.runnable_key_set, key)
        }

        if runnable?(state, key), do: {key, state}, else: pop_runnable(state)

      {:empty, _runnable_keys} ->
        :empty
    end
  end

  defp runnable?(state, key) do
    not Map.has_key?(state.active, key) and
      case Map.fetch(state.queues, key) do
        {:ok, queue} -> not :queue.is_empty(queue)
        :error -> false
      end
  end

  defp active_by_ref(active, ref) do
    Enum.find(active, fn {_key, task} -> task.ref == ref end)
  end

  defp queue_entry(key, entry, state) do
    queue = Map.get(state.queues, key, :queue.new())

    state = %{
      state
      | queues: Map.put(state.queues, key, :queue.in(entry, queue)),
        pending: state.pending + 1
    }

    state
    |> make_runnable(key)
  end

  defp make_runnable(state, key) do
    if runnable?(state, key) and not MapSet.member?(state.runnable_key_set, key) do
      %{
        state
        | runnable_keys: :queue.in(key, state.runnable_keys),
          runnable_key_set: MapSet.put(state.runnable_key_set, key)
      }
    else
      state
    end
  end

  defp entry(operation, timeout, reply_to, log_context, state) do
    %{
      log_context: log_context,
      operation: operation,
      timeout: resolve_timeout(timeout, state.operation_timeout_ms),
      reply_to: reply_to
    }
  end

  defp safely_run(operation) do
    operation.()
  rescue
    error -> {:error, {:coordination_operation_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:coordination_operation_failure, kind, reason}}
  end

  defp start_task(entry) do
    {:ok, Task.Supervisor.async(Aiur.TaskSupervisor, fn -> safely_run(entry.operation) end)}
  end

  defp safely_start_task(starter, entry) do
    case starter.(entry) do
      {:ok, %Task{} = task} -> {:ok, task}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_task_starter_result, other}}
    end
  rescue
    error -> {:error, {:task_start_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:task_start_failure, kind, reason}}
  end

  defp log_failure(key, task, {:error, reason}) do
    %{issue_id: issue_id, issue_identifier: issue_identifier} = task.log_context

    Logger.error(
      "coordination operation failed key=#{safe_detail(key)} ticket=#{safe_detail(key_ticket(key))} " <>
        "issue_id=#{safe_detail(issue_id)} issue_identifier=#{safe_detail(issue_identifier)} " <>
        "failure=#{safe_detail(reason)} timeout_ms=#{task.operation_timeout}"
    )
  end

  defp log_failure(_key, _task, _result), do: :ok

  defp key_ticket({:event, ticket}), do: ticket
  defp key_ticket({:dependency, ticket, _blocker}), do: ticket
  defp key_ticket({:ticket, ticket}), do: ticket
  defp key_ticket(_key), do: nil

  defp log_context(opts) do
    case Keyword.get(opts, :log_context) do
      context when is_map(context) ->
        %{
          issue_id: Map.get(context, :issue_id),
          issue_identifier: Map.get(context, :issue_identifier)
        }

      _other ->
        %{issue_id: nil, issue_identifier: nil}
    end
  end

  defp safe_detail(value) do
    SecretRedactor.safe_inspect(value, @max_failure_chars)
  end

  defp admission_deadline(:infinity), do: :infinity

  defp admission_deadline(timeout) when is_integer(timeout) and timeout >= 0 do
    System.monotonic_time(:millisecond) + timeout
  end

  defp admission_expired?(:infinity), do: false
  defp admission_expired?(deadline), do: System.monotonic_time(:millisecond) >= deadline

  defp admission_available?(state, key) do
    state.pending < state.max_pending and
      pending_for_key(state, key) < state.max_pending_per_key
  end

  defp pending_for_key(state, key) do
    state.queues
    |> Map.get(key, :queue.new())
    |> :queue.len()
  end

  defp default_per_key_limit(max_pending) when max_pending > 1, do: max_pending - 1
  defp default_per_key_limit(_max_pending), do: 1

  defp coordination_exit(:noproc), do: {:error, :coordination_unavailable}
  defp coordination_exit({:noproc, _call}), do: {:error, :coordination_unavailable}
  defp coordination_exit(_reason), do: {:error, :coordination_indeterminate}

  defp resolve_timeout(:default, default), do: default
  defp resolve_timeout(:infinity, _default), do: :infinity
  defp resolve_timeout(timeout, _default) when is_integer(timeout) and timeout > 0, do: timeout

  defp schedule_timeout(_ref, :infinity), do: nil
  defp schedule_timeout(ref, timeout), do: Process.send_after(self(), {:coordination_timeout, ref}, timeout)
end
