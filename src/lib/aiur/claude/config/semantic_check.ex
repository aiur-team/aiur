defmodule Aiur.Claude.Config.SemanticCheck do
  @moduledoc false
  @behaviour Aiur.Config.SemanticCheck

  alias Aiur.Claude.Config

  @impl true
  def applies?(settings), do: settings.agent.kind == "claude"

  @impl true
  def check(_settings), do: Config.validate!()
end
