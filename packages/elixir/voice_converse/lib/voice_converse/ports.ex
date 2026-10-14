defmodule VoiceConverse.Ports do
  @moduledoc """
  Port deadlines and the one helper that enforces them.

  A timeout or exit becomes `{:error, :unavailable}`, never an empty value that could read as
  "idle" or "nothing open".
  """

  @deadlines_ms %{brief: 100, details: 300, ask: 300, instruct: 300, answer: 300, fetch: 50}

  @type op :: :brief | :details | :ask | :instruct | :answer | :fetch

  @spec deadline_ms(op()) :: pos_integer()
  def deadline_ms(op), do: Map.fetch!(@deadlines_ms, op)

  @doc "Calls `module.fun(*args)` in a monitored process under the deadline for `op`."
  @spec call_port(module(), atom(), [term()], op()) :: term() | {:error, :unavailable}
  def call_port(module, fun, args, op) do
    parent = self()
    ref = make_ref()
    {pid, mon} = spawn_monitor(fn -> send(parent, {ref, apply(module, fun, args)}) end)

    receive do
      {^ref, result} ->
        Process.demonitor(mon, [:flush])
        result

      {:DOWN, ^mon, :process, ^pid, _reason} ->
        {:error, :unavailable}
    after
      deadline_ms(op) ->
        Process.exit(pid, :kill)
        Process.demonitor(mon, [:flush])

        receive do
          {^ref, _late} -> :ok
        after
          0 -> :ok
        end

        {:error, :unavailable}
    end
  end
end
