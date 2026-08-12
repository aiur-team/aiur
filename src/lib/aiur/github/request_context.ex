defmodule Aiur.GitHub.RequestContext do
  @moduledoc false

  @deadline_key {__MODULE__, :deadline_ms}

  @spec run(pos_integer(), (-> term())) :: term()
  def run(timeout_ms, fun) when is_integer(timeout_ms) and timeout_ms > 0 and is_function(fun, 0) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    run_until(deadline_ms, fun)
  end

  @spec active?() :: boolean()
  def active?, do: is_integer(Process.get(@deadline_key))

  @spec wrap((term() -> term())) :: (term() -> term())
  def wrap(fun) when is_function(fun, 1) do
    deadline_ms = Process.get(@deadline_key)

    fn value ->
      if is_integer(deadline_ms), do: run_until(deadline_ms, fn -> fun.(value) end), else: fun.(value)
    end
  end

  defp run_until(deadline_ms, fun) do
    previous = Process.put(@deadline_key, deadline_ms)

    try do
      fun.()
    after
      restore_deadline(previous)
    end
  end

  @spec timeout_ms(pos_integer()) :: pos_integer()
  def timeout_ms(default) when is_integer(default) and default > 0 do
    case Process.get(@deadline_key) do
      deadline_ms when is_integer(deadline_ms) ->
        remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 1)
        min(default, remaining_ms)

      _missing ->
        default
    end
  end

  defp restore_deadline(nil), do: Process.delete(@deadline_key)
  defp restore_deadline(previous), do: Process.put(@deadline_key, previous)
end
