defmodule Aiur.Config.Schema.TurnSandboxPolicyCheck do
  @moduledoc false
  @behaviour Aiur.Config.SemanticCheck

  alias Aiur.Config.Schema

  @impl true
  def applies?(_settings), do: true

  @impl true
  def check(settings), do: Schema.validate_turn_sandbox_policy(settings)
end
