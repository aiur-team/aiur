defmodule Aiur.AgentSetupScout.Reporter do
  @moduledoc """
  Behaviour for reporting setup-friction optimization findings.
  """

  @callback report(map()) :: :ok | {:ok, term()} | {:error, term()}
end
