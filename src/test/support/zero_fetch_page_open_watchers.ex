defmodule Aiur.TestSupport.ZeroFetchPageOpenWatchers do
  @moduledoc false

  import ExUnit.Assertions

  @watchers [
    Aiur.MainWatch,
    Aiur.LandingWatch,
    Aiur.LandingWatch.QuarantineLifter,
    Aiur.GitHub.ViewStateSweep,
    Aiur.PRLifecycle.HealthScanner,
    Aiur.PRLifecycle.HeadVerdictRouter,
    Aiur.PRLifecycle.ReworkRequeue,
    Aiur.AllowedContributors
  ]

  @spec suspend((pid() -> any())) :: :ok
  def suspend(on_suspended) when is_function(on_suspended, 1) do
    Enum.each(@watchers, &suspend_watcher(&1, on_suspended))
  end

  @spec resume(pid()) :: :ok
  def resume(pid) do
    if Process.alive?(pid) do
      try do
        :sys.resume(pid)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  defp suspend_watcher(name, on_suspended) do
    case Process.whereis(name) do
      pid when is_pid(pid) ->
        case await_idle(pid, name) do
          :ok ->
            await_inflight_tasks(name)
            suspend_pid(name, pid, on_suspended)

          :gone ->
            :ok
        end

      nil ->
        :ok
    end
  end

  defp suspend_pid(name, pid, on_suspended) do
    if Process.alive?(pid) do
      try do
        :ok = :sys.suspend(pid)
        on_suspended.(pid)
        await_inflight_tasks(name)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  defp await_inflight_tasks(Aiur.LandingWatch.QuarantineLifter) do
    # Its timer handler starts detached children, so suspending the GenServer
    # alone cannot wait for a quarantine-file read already in progress.
    Aiur.TaskSupervisor
    |> Task.Supervisor.children()
    |> Enum.filter(&quarantine_lifter_task?/1)
    |> Enum.map(&{&1, Process.monitor(&1)})
    |> Enum.each(fn {pid, ref} ->
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 40_000, "quarantine-lifter task did not finish before the GitHub request counter was installed"
    end)
  end

  defp await_inflight_tasks(_watcher), do: :ok

  defp quarantine_lifter_task?(pid) do
    case Process.info(pid, :current_stacktrace) do
      {:current_stacktrace, stacktrace} -> Enum.any?(stacktrace, &match?({Aiur.LandingWatch.QuarantineLifter, _, _, _}, &1))
      nil -> false
    end
  end

  defp await_idle(pid, name) when name in [Aiur.MainWatch, Aiur.LandingWatch] do
    await_state(pid, &is_nil(&1.task), System.monotonic_time(:millisecond) + 5_000)
  end

  defp await_idle(pid, _periodic_worker) do
    # This state call is a barrier behind any synchronous periodic tick.
    case get_state(pid) do
      {:ok, _state} -> :ok
      :gone -> :gone
    end
  end

  defp await_state(pid, predicate, deadline) do
    case get_state(pid) do
      {:ok, state} ->
        cond do
          predicate.(state) ->
            :ok

          System.monotonic_time(:millisecond) >= deadline ->
            raise "timed out waiting for #{inspect(pid)} to finish its GitHub poll"

          true ->
            Process.sleep(10)
            await_state(pid, predicate, deadline)
        end

      :gone ->
        :gone
    end
  end

  defp get_state(pid) do
    {:ok, :sys.get_state(pid)}
  catch
    :exit, _ -> :gone
  end
end
