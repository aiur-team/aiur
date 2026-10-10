defmodule AiurWeb.OperatorControlCenter.LoadBudget do
  @moduledoc """
  Bounds the provider reads of one dashboard payload load.

  The providers are `GenServer.call`s with a 5 s default each, read one after
  another, while `AiurWeb.ControlCenterCache` kills the whole load at its load
  timeout and re-serves the previous payload. One slow provider therefore froze
  every surface for as long as it stayed slow (#3937). A bounded read gives up
  on its own provider instead: it exits, the caller's existing guard turns that
  into that provider's unavailable state, and the rest of the payload loads.

  All reads of one load share a deadline, so together they cannot outlast the
  budget. Each read is also capped at a quarter of it, so the first slow
  provider cannot spend the time of the ones read after it.
  """

  @type bound :: ((-> term()) -> (-> term()))

  @doc "Starts a budget of `budget_ms` and returns the wrapper for this load's provider reads."
  @spec bound(non_neg_integer()) :: bound()
  def bound(budget_ms) when is_integer(budget_ms) and budget_ms >= 0 do
    deadline_ms = now_ms() + budget_ms
    read_cap_ms = max(div(budget_ms, 4), 1)

    fn fun when is_function(fun, 0) ->
      fn -> read(fun, min(read_cap_ms, max(deadline_ms - now_ms(), 0))) end
    end
  end

  # Linked on purpose: if the cache kills the load, the read dies with it.
  defp read(fun, timeout_ms) do
    task =
      Task.async(fn ->
        try do
          {:ok, fun.()}
        catch
          kind, reason -> {kind, reason, __STACKTRACE__}
        end
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, value}} -> value
      {:ok, {kind, reason, stacktrace}} -> :erlang.raise(kind, reason, stacktrace)
      {:exit, reason} -> exit(reason)
      nil -> exit(:load_budget_exceeded)
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
