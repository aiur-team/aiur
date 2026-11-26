defmodule Aiur.ControlCall.Allowlist.Facade do
  @moduledoc false

  @spec functions() :: [{atom(), non_neg_integer()}]
  def functions, do: Aiur.AgentControlCLI.__info__(:functions)
end
