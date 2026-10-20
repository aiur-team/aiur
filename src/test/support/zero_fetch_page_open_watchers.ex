defmodule Aiur.TestSupport.ZeroFetchPageOpenWatchers do
  @moduledoc false

  @watchers [
    Aiur.MainWatch,
    Aiur.LandingWatch,
    Aiur.PRLifecycle.HealthScanner,
    Aiur.PRLifecycle.HeadVerdictRouter,
    Aiur.PRLifecycle.ReworkRequeue
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
          :ok -> suspend_pid(pid, on_suspended)
          :gone -> :ok
        end

      nil ->
        :ok
    end
  end

  defp suspend_pid(pid, on_suspended) do
    if Process.alive?(pid) do
      try do
        :ok = :sys.suspend(pid)
        on_suspended.(pid)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
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
