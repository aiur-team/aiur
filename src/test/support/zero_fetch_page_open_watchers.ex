defmodule Aiur.TestSupport.ZeroFetchPageOpenWatchers do
  @moduledoc false

  @watchers [
    Aiur.MainWatch,
    Aiur.LandingWatch,
    Aiur.PRLifecycle.HealthScanner,
    Aiur.PRLifecycle.HeadVerdictRouter,
    Aiur.PRLifecycle.ReworkRequeue
  ]

  def suspend do
    Enum.flat_map(@watchers, fn name ->
      case Process.whereis(name) do
        pid when is_pid(pid) ->
          await_idle(pid, name)
          :ok = :sys.suspend(pid)
          [pid]

        nil ->
          []
      end
    end)
  end

  defp await_idle(pid, name) when name in [Aiur.MainWatch, Aiur.LandingWatch] do
    await_state(pid, &is_nil(&1.task))
  end

  defp await_idle(pid, _periodic_worker) do
    # A synchronous tick completes before the GenServer answers this state call.
    _state = :sys.get_state(pid)
    :ok
  end

  defp await_state(pid, predicate) do
    if predicate.(:sys.get_state(pid)),
      do: :ok,
      else:
        (
          Process.sleep(10)
          await_state(pid, predicate)
        )
  end
end
