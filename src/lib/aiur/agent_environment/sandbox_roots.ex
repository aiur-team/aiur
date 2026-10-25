defmodule Aiur.AgentEnvironment.SandboxRoots do
  @moduledoc false
  @behaviour Aiur.Config.TurnSandboxRoots

  alias Aiur.AgentEnvironment
  alias Aiur.Config.Schema

  @impl true
  def contribute(turn_sandbox_policy, _settings, opts) do
    cond do
      Keyword.get(opts, :remote, false) ->
        {:ok, turn_sandbox_policy}

      not Schema.workspace_write_policy?(turn_sandbox_policy) ->
        {:ok, turn_sandbox_policy}

      true ->
        Schema.add_runtime_turn_sandbox_roots(turn_sandbox_policy, AgentEnvironment.package_cache_paths(opts))
    end
  end
end
