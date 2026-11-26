defmodule Aiur.CodingAgent.Backend.ToolInvocation do
  @moduledoc """
  Carries one native tool-call identity through its executor callback.

  Runner-side tool execution delegates to this contract helper so backend
  adapters do not depend on the application runner module.
  """

  @invocation_key {__MODULE__, :invocation_id}

  @spec execute((String.t(), term() -> map()), String.t() | nil, term(), term()) :: map()
  def execute(executor, tool, arguments, invocation_id) when is_function(executor, 2) do
    previous = Process.get(@invocation_key, :unset)
    Process.put(@invocation_key, invocation_id)

    try do
      executor.(tool, arguments)
    after
      restore_invocation(previous)
    end
  end

  @spec invocation_id() :: term()
  def invocation_id, do: Process.get(@invocation_key)

  defp restore_invocation(:unset), do: Process.delete(@invocation_key)
  defp restore_invocation(value), do: Process.put(@invocation_key, value)
end
