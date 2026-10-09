defmodule Aiur.CodingAgent.SemanticCheck.Dispatchable do
  @moduledoc false
  @behaviour Aiur.Config.SemanticCheck

  @impl true
  def applies?(settings), do: settings.agent.kind not in Aiur.CodingAgent.dispatchable_backends(settings.agent.backend_configs)

  @impl true
  def check(settings), do: {:error, {:unsupported_agent_kind, settings.agent.kind}}
end
