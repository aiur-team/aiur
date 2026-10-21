defmodule Aiur.GitHub.BudgetBroker do
  @moduledoc "Owns the daemon's persistent, correlated budget broker port."
  use GenServer

  require Logger

  @telemetry_event [:aiur, :github, :budget_broker, :command]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec command(GenServer.server(), String.t(), [String.t()], integer()) :: term()
  def command(server, broker, args, deadline_at) do
    # The timer belongs to the port owner, so expired responses cannot be read
    # as the next caller's response. No timeout kills another caller's work.
    submitted_at = System.monotonic_time(:millisecond)
    GenServer.call(server, {:command, broker, args, deadline_at, submitted_at}, :infinity)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    Process.send_after(self(), :report_stats, :timer.minutes(1))
    {:ok, %{python: Keyword.get(opts, :python, System.find_executable("python3")), port: nil, pending: %{}, next_id: 0, buffer: "", stats: []}}
  end

  @impl true
  def handle_call({:command, broker, args, deadline_at, submitted_at}, from, state) do
    remaining = deadline_at - System.monotonic_time(:millisecond)
    mailbox_wait_ms = max(System.monotonic_time(:millisecond) - submitted_at, 0)

    if remaining <= 0 do
      measurements = %{
        duration_ms: mailbox_wait_ms,
        mailbox_wait_ms: mailbox_wait_ms,
        pending: map_size(state.pending),
        mailbox: message_queue_len(),
        command_type: args |> List.first() |> safe_command_type()
      }

      observe_command(:deadline_expired, measurements)
      {:reply, :timeout, add_sample(state, :deadline_expired, measurements)}
    else
      enqueue(state, broker, args, remaining, from, submitted_at, mailbox_wait_ms)
    end
  end

  defp enqueue(state, broker, args, remaining, from, submitted_at, mailbox_wait_ms) do
    id = state.next_id
    enqueue_request(%{state | next_id: id + 1}, broker, args, remaining, from, id, submitted_at, mailbox_wait_ms)
  end

  defp enqueue_request(state, broker, args, remaining, from, id, submitted_at, mailbox_wait_ms) do
    payload = Jason.encode!(%{id: id, args: args, deadline_ms: System.system_time(:millisecond) + remaining}) <> "\n"
    state = ensure_port(state, broker)
    timer = Process.send_after(self(), {:deadline, id}, remaining)
    command_type = args |> List.first() |> safe_command_type()
    next = %{state | pending: Map.put(state.pending, id, {from, timer, submitted_at, mailbox_wait_ms, command_type})}
    send_request(next, payload, id)
  rescue
    _error -> {:reply, :timeout, state}
  end

  defp send_request(state, payload, id) do
    if Port.command(state.port, payload, [:nosuspend]), do: {:noreply, state}, else: {:noreply, complete(state, id, :timeout)}
  rescue
    _error -> {:noreply, fail_pending(state)}
  end

  defp ensure_port(%{port: nil} = state, broker) do
    port = Port.open({:spawn_executable, String.to_charlist(state.python)}, [:binary, :exit_status, :use_stdio, args: [broker, "serve"]])
    %{state | port: port, buffer: ""}
  end

  defp ensure_port(state, _broker), do: state

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    lines = String.split(state.buffer <> data, "\n")
    {complete, [buffer]} = Enum.split(lines, -1)
    {:noreply, Enum.reduce(complete, %{state | buffer: buffer}, &reply_line/2)}
  end

  def handle_info({:deadline, id}, state), do: {:noreply, expire(state, id)}

  def handle_info({:forget_late, id}, state) do
    case Map.get(state.pending, id) do
      {nil, _timer, _submitted_at, _mailbox_wait_ms, _command_type} -> {:noreply, %{state | pending: Map.delete(state.pending, id)}}
      _active -> {:noreply, state}
    end
  end

  def handle_info(:report_stats, state) do
    if state.stats != [] do
      summary = summarize_stats(state.stats)
      Logger.info("GitHub budget broker one-minute measurements=#{inspect(summary)}")
      :telemetry.execute([:aiur, :github, :budget_broker, :window], Map.delete(summary, :by_command_type), %{})
    end

    Process.send_after(self(), :report_stats, :timer.minutes(1))
    {:noreply, %{state | stats: []}}
  end

  def handle_info({port, {:exit_status, _status}}, %{port: port} = state) do
    state = Enum.reduce(Map.keys(state.pending), state, &complete(&2, &1, :timeout))
    {:noreply, %{state | port: nil, buffer: ""}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp reply_line(line, state) do
    case Jason.decode(line) do
      {:ok, %{"id" => id, "output" => output, "status" => status} = reply} ->
        metrics =
          Map.take(reply, [
            "python_queue_wait_ms",
            "python_queue_depth",
            "sqlite_open_ms",
            "sqlite_lock_wait_ms",
            "sqlite_transaction_ms",
            "sqlite_command_ms",
            "sqlite_commit_ms",
            "sqlite_checkpoint_ms",
            "sqlite_checkpoint_busy",
            "sqlite_wal_frames",
            "sqlite_checkpointed_frames",
            "command_type"
          ])

        complete(state, id, if(status == 2, do: {:timeout, metrics}, else: {:ok, output, status, metrics}))

      _invalid ->
        fail_pending(state, {:error, :invalid_broker_reply})
    end
  end

  defp fail_pending(state, result \\ :timeout) do
    if Port.info(state.port), do: Port.close(state.port)
    state = Enum.reduce(Map.keys(state.pending), state, &complete(&2, &1, result))
    %{state | port: nil, buffer: ""}
  end

  defp complete(state, id, result) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        state

      {{nil, _timer, submitted_at, mailbox_wait_ms, command_type}, pending} ->
        late_response(%{state | pending: pending}, result, submitted_at, mailbox_wait_ms, command_type)

      {{from, timer, submitted_at, mailbox_wait_ms, command_type}, pending} ->
        Process.cancel_timer(timer)
        {public_result, outcome, python_metrics} = public_result(result)
        GenServer.reply(from, public_result)

        measurements =
          %{duration_ms: System.monotonic_time(:millisecond) - submitted_at, mailbox_wait_ms: mailbox_wait_ms, pending: map_size(pending), mailbox: message_queue_len()}
          |> put_metric(:python_queue_wait_ms, python_metrics["python_queue_wait_ms"])
          |> put_metric(:python_queue_depth, python_metrics["python_queue_depth"])
          |> put_metric(:sqlite_open_ms, python_metrics["sqlite_open_ms"])
          |> put_metric(:sqlite_lock_wait_ms, python_metrics["sqlite_lock_wait_ms"])
          |> put_metric(:sqlite_transaction_ms, python_metrics["sqlite_transaction_ms"])
          |> put_metric(:sqlite_command_ms, python_metrics["sqlite_command_ms"])
          |> put_metric(:sqlite_commit_ms, python_metrics["sqlite_commit_ms"])
          |> put_metric(:sqlite_checkpoint_ms, python_metrics["sqlite_checkpoint_ms"])
          |> put_metric(:sqlite_checkpoint_busy, python_metrics["sqlite_checkpoint_busy"])
          |> put_metric(:sqlite_wal_frames, python_metrics["sqlite_wal_frames"])
          |> put_metric(:sqlite_checkpointed_frames, python_metrics["sqlite_checkpointed_frames"])
          |> Map.put(:command_type, safe_command_type(python_metrics["command_type"]) |> prefer_command_type(command_type))

        observe_command(outcome, measurements)
        state |> Map.put(:pending, pending) |> add_sample(outcome, measurements)
    end
  end

  defp expire(state, id) do
    case Map.get(state.pending, id) do
      {from, timer, submitted_at, mailbox_wait_ms, command_type} when not is_nil(from) ->
        Process.cancel_timer(timer)
        GenServer.reply(from, :timeout)

        measurements = %{
          duration_ms: System.monotonic_time(:millisecond) - submitted_at,
          mailbox_wait_ms: mailbox_wait_ms,
          pending: max(map_size(state.pending) - 1, 0),
          mailbox: message_queue_len(),
          command_type: command_type
        }

        observe_command(:timeout, measurements)
        cleanup = Process.send_after(self(), {:forget_late, id}, :timer.minutes(1))
        state |> put_in([:pending, id], {nil, cleanup, submitted_at, mailbox_wait_ms, command_type}) |> add_sample(:timeout, measurements)

      _already_expired_or_completed ->
        state
    end
  end

  defp late_response(state, :timeout, _submitted_at, _mailbox_wait_ms, _command_type), do: state

  defp late_response(state, result, submitted_at, mailbox_wait_ms, command_type) do
    {_public_result, _outcome, python_metrics} = public_result(result)

    measurements =
      %{late_duration_ms: System.monotonic_time(:millisecond) - submitted_at, mailbox_wait_ms: mailbox_wait_ms, pending: map_size(state.pending), mailbox: message_queue_len()}
      |> put_metric(:python_queue_wait_ms, python_metrics["python_queue_wait_ms"])
      |> put_metric(:python_queue_depth, python_metrics["python_queue_depth"])
      |> put_metric(:sqlite_open_ms, python_metrics["sqlite_open_ms"])
      |> put_metric(:sqlite_lock_wait_ms, python_metrics["sqlite_lock_wait_ms"])
      |> put_metric(:sqlite_transaction_ms, python_metrics["sqlite_transaction_ms"])
      |> put_metric(:sqlite_command_ms, python_metrics["sqlite_command_ms"])
      |> put_metric(:sqlite_commit_ms, python_metrics["sqlite_commit_ms"])
      |> put_metric(:sqlite_checkpoint_ms, python_metrics["sqlite_checkpoint_ms"])
      |> put_metric(:sqlite_checkpoint_busy, python_metrics["sqlite_checkpoint_busy"])
      |> put_metric(:sqlite_wal_frames, python_metrics["sqlite_wal_frames"])
      |> put_metric(:sqlite_checkpointed_frames, python_metrics["sqlite_checkpointed_frames"])
      |> Map.put(:command_type, safe_command_type(python_metrics["command_type"]) |> prefer_command_type(command_type))

    observe_command(:late_response, measurements)
    add_sample(state, :late_response, measurements)
  end

  defp public_result(:timeout), do: {:timeout, :timeout, %{}}
  defp public_result({:timeout, metrics}), do: {:timeout, :timeout, metrics}
  defp public_result({:ok, output, status, metrics}), do: {{:ok, output, status}, :completed, metrics}
  defp public_result({:error, _} = error), do: {error, :error, %{}}

  defp observe_command(outcome, measurements) do
    command_type = Map.get(measurements, :command_type, :unknown)
    :telemetry.execute(@telemetry_event, Map.delete(measurements, :command_type), %{outcome: outcome, command_type: command_type})
  rescue
    _error -> :ok
  end

  defp add_sample(state, outcome, measurements), do: %{state | stats: [{outcome, measurements} | state.stats]}

  @doc false
  @spec summarize_stats([{atom(), map()}]) :: map()
  def summarize_stats(samples) do
    measurements = Enum.map(samples, &elem(&1, 1))

    by_command_type =
      samples
      |> Enum.group_by(fn {_outcome, sample} -> Map.get(sample, :command_type, :unknown) end)
      |> Map.new(fn {command_type, grouped} -> {command_type, summarize_group(grouped)} end)

    %{
      commands: Enum.count(samples, fn {outcome, _measurements} -> outcome != :late_response end),
      timeouts: Enum.count(samples, fn {outcome, _measurements} -> outcome in [:timeout, :deadline_expired] end),
      late_responses: Enum.count(samples, fn {outcome, _measurements} -> outcome == :late_response end),
      duration_p50_ms: percentile(measurements, :duration_ms, 0.50),
      duration_p99_ms: percentile(measurements, :duration_ms, 0.99),
      late_duration_p50_ms: percentile(measurements, :late_duration_ms, 0.50),
      late_duration_p99_ms: percentile(measurements, :late_duration_ms, 0.99),
      mailbox_wait_p50_ms: percentile(measurements, :mailbox_wait_ms, 0.50),
      mailbox_wait_p99_ms: percentile(measurements, :mailbox_wait_ms, 0.99),
      mailbox_depth_max: maximum(measurements, :mailbox),
      pending_max: maximum(measurements, :pending),
      python_queue_wait_p50_ms: percentile(measurements, :python_queue_wait_ms, 0.50),
      python_queue_wait_p99_ms: percentile(measurements, :python_queue_wait_ms, 0.99),
      python_queue_depth_max: maximum(measurements, :python_queue_depth),
      sqlite_open_p50_ms: percentile(measurements, :sqlite_open_ms, 0.50),
      sqlite_open_p99_ms: percentile(measurements, :sqlite_open_ms, 0.99),
      sqlite_lock_wait_p50_ms: percentile(measurements, :sqlite_lock_wait_ms, 0.50),
      sqlite_lock_wait_p99_ms: percentile(measurements, :sqlite_lock_wait_ms, 0.99),
      sqlite_transaction_p50_ms: percentile(measurements, :sqlite_transaction_ms, 0.50),
      sqlite_transaction_p99_ms: percentile(measurements, :sqlite_transaction_ms, 0.99),
      sqlite_command_p99_ms: percentile(measurements, :sqlite_command_ms, 0.99),
      sqlite_commit_p99_ms: percentile(measurements, :sqlite_commit_ms, 0.99),
      sqlite_checkpoint_p99_ms: percentile(measurements, :sqlite_checkpoint_ms, 0.99),
      by_command_type: by_command_type
    }
  end

  defp summarize_group(samples) do
    measurements = Enum.map(samples, &elem(&1, 1))

    %{
      commands: length(samples),
      timeouts: Enum.count(samples, fn {outcome, _} -> outcome in [:timeout, :deadline_expired] end),
      duration_p99_ms: percentile(measurements, :duration_ms, 0.99),
      python_queue_wait_p99_ms: percentile(measurements, :python_queue_wait_ms, 0.99),
      sqlite_lock_wait_p99_ms: percentile(measurements, :sqlite_lock_wait_ms, 0.99),
      sqlite_command_p99_ms: percentile(measurements, :sqlite_command_ms, 0.99),
      sqlite_commit_p99_ms: percentile(measurements, :sqlite_commit_ms, 0.99)
    }
  end

  defp percentile(samples, key, ratio) do
    values = samples |> Enum.flat_map(&maybe_value(&1, key)) |> Enum.sort()
    if values == [], do: nil, else: Enum.at(values, max(ceil(length(values) * ratio) - 1, 0))
  end

  defp maximum(samples, key) do
    samples |> Enum.flat_map(&maybe_value(&1, key)) |> Enum.max(fn -> nil end)
  end

  defp maybe_value(sample, key) do
    case Map.get(sample, key) do
      value when is_number(value) -> [value]
      _ -> []
    end
  end

  defp put_metric(measurements, _key, nil), do: measurements
  defp put_metric(measurements, key, value) when is_number(value), do: Map.put(measurements, key, value)
  defp put_metric(measurements, _key, _value), do: measurements

  defp message_queue_len do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, length} -> length
      _unavailable -> 0
    end
  end

  defp safe_command_type("acquire"), do: :acquire
  defp safe_command_type("release"), do: :release
  defp safe_command_type("reconcile"), do: :reconcile
  defp safe_command_type("renew"), do: :renew
  defp safe_command_type("hold"), do: :hold
  defp safe_command_type("snapshot"), do: :snapshot
  defp safe_command_type("usage"), do: :usage
  defp safe_command_type("meter"), do: :meter
  defp safe_command_type(_type), do: :unknown
  defp prefer_command_type(:unknown, fallback), do: fallback
  defp prefer_command_type(command_type, _fallback), do: command_type
end
