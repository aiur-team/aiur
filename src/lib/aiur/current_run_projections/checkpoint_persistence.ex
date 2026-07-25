defmodule Aiur.CurrentRunProjections.CheckpointPersistence do
  @moduledoc false

  alias Aiur.CurrentRunProjections.Checkpoint

  @spec start(map(), map(), keyword(), pid()) :: map()
  def start(state, candidate, opts, owner \\ self()) do
    generation =
      max(
        System.unique_integer([:positive, :monotonic]),
        Map.get(state, :checkpoint_generation, 0) + 1
      )

    candidate = Checkpoint.candidate(candidate, generation)
    timeout_ms = state.checkpoint_timeout_ms

    checkpoint =
      candidate
      |> Checkpoint.dump()
      |> Map.put(:checkpoint_deadline_monotonic_ms, System.monotonic_time(:millisecond) + timeout_ms)

    ref = make_ref()
    writer = state.checkpoint_writer
    run_id = Map.get(candidate, :run_id)

    pid =
      start_task(state.task_supervisor, fn ->
        result = Checkpoint.write(writer, run_id, checkpoint)
        send(owner, {:current_run_checkpoint_result, ref, generation, result})
      end)

    timer =
      Process.send_after(
        owner,
        {:current_run_checkpoint_deadline, ref, generation},
        timeout_ms
      )

    canonical = restore_canonical(state)

    %{
      canonical
      | refresh: nil,
        checkpoint_write: %{
          ref: ref,
          generation: generation,
          pid: pid,
          timer: timer,
          candidate: candidate,
          changes: Keyword.fetch!(opts, :changes),
          race_signature: Keyword.get(opts, :race_signature),
          force_full?: Keyword.get(opts, :force_full?, false),
          waiters: Keyword.get(opts, :waiters, [])
        }
    }
  end

  @spec finish(map(), reference(), pos_integer(), term()) ::
          {:ok, map(), map(), term()} | :stale
  def finish(
        %{checkpoint_write: %{ref: ref, generation: generation} = write} = state,
        ref,
        generation,
        result
      ) do
    _ = Process.cancel_timer(write.timer)
    {:ok, %{state | checkpoint_write: nil}, write, result}
  end

  def finish(_state, _ref, _generation, _result), do: :stale

  @spec expire(map(), reference(), pos_integer()) ::
          {:ok, map(), map(), {:error, :checkpoint_write_failed}} | :stale
  def expire(
        %{checkpoint_write: %{ref: ref, generation: generation} = write} = state,
        ref,
        generation
      ) do
    stop_task(write.pid)

    {:ok, %{state | checkpoint_write: nil}, write, {:error, :checkpoint_write_failed}}
  end

  def expire(_state, _ref, _generation), do: :stale

  @spec stop(map() | nil) :: :ok
  def stop(%{pid: pid, timer: timer}) do
    _ = Process.cancel_timer(timer)
    stop_task(pid)
  end

  def stop(_write), do: :ok

  defp restore_canonical(%{refresh: %{base_summary: summary, base_outcomes: outcomes}} = state) do
    %{state | summary_snapshot: summary, outcome_snapshot: outcomes}
  end

  defp restore_canonical(state), do: state

  defp start_task(nil, fun) do
    {:ok, pid} = Task.start(fun)
    pid
  end

  defp start_task(supervisor, fun) do
    case safe_supervised_start(supervisor, fun) do
      {:ok, pid} -> pid
      {:error, _reason} -> start_task(nil, fun)
    end
  end

  defp safe_supervised_start(supervisor, fun) do
    Task.Supervisor.start_child(supervisor, fun)
  catch
    :exit, _reason -> {:error, :supervisor_unavailable}
  end

  defp stop_task(pid) when is_pid(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
    :ok
  end

  defp stop_task(_pid), do: :ok
end
