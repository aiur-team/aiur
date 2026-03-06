defmodule SymphonyElixir.AgentConfig do
  @moduledoc """
  Behaviour for coding-agent-specific configuration modules.
  """

  @callback validate!() :: :ok | {:error, String.t()}
end
