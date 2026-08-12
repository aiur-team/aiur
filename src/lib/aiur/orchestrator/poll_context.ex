defmodule Aiur.Orchestrator.PollContext do
  @moduledoc """
  Preserves orchestrator process ownership while the serialized poll pipeline
  runs in a supervised task.

  Timers can target the owner directly. Process monitors must be created and
  removed by their owner, so those operations proxy through the orchestrator
  without moving network work back into its mailbox.
  """

  @owner_key {__MODULE__, :owner}
  @proxy_timeout_ms 1_000
  @github_request_timeout_ms 3_000

  @spec run(pid(), (-> term())) :: term()
  def run(owner, fun) when is_pid(owner) and is_function(fun, 0) do
    previous = Process.put(@owner_key, owner)

    try do
      Aiur.GitHub.RequestContext.run(@github_request_timeout_ms, fun)
    after
      restore_owner(previous)
    end
  end

  @spec owner() :: pid()
  def owner do
    case Process.get(@owner_key) do
      pid when is_pid(pid) -> pid
      _missing -> self()
    end
  end

  @spec active?() :: boolean()
  def active?, do: is_pid(Process.get(@owner_key))

  @spec monitor(pid()) :: reference()
  def monitor(pid) when is_pid(pid) do
    owner = owner()

    if owner == self() do
      Process.monitor(pid)
    else
      proxy(owner, {:monitor, pid})
    end
  end

  @spec demonitor(reference(), [atom()]) :: boolean()
  def demonitor(ref, opts \\ []) when is_reference(ref) and is_list(opts) do
    owner = owner()

    if owner == self() do
      Process.demonitor(ref, opts)
    else
      proxy(owner, {:demonitor, ref, opts})
    end
  end

  @spec send_after(term(), non_neg_integer()) :: reference()
  def send_after(message, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    Process.send_after(owner(), message, delay_ms)
  end

  defp proxy(owner, operation) do
    token = make_ref()
    send(owner, {:poll_context_request, self(), token, operation})

    receive do
      {:poll_context_reply, ^token, result} -> result
    after
      @proxy_timeout_ms -> exit({:poll_context_timeout, operation})
    end
  end

  defp restore_owner(nil), do: Process.delete(@owner_key)
  defp restore_owner(previous), do: Process.put(@owner_key, previous)
end
