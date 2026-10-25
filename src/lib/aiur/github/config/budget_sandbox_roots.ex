defmodule Aiur.GitHub.Budget.SandboxRoots do
  @moduledoc false
  @behaviour Aiur.Config.TurnSandboxRoots

  alias Aiur.Config.Schema
  alias Aiur.GitHub.Access

  @impl true
  def contribute(turn_sandbox_policy, _settings, opts) do
    cond do
      Keyword.get(opts, :remote, false) ->
        {:ok, turn_sandbox_policy}

      not Schema.workspace_write_policy?(turn_sandbox_policy) ->
        {:ok, turn_sandbox_policy}

      not Access.budget_enabled?() ->
        {:ok, turn_sandbox_policy}

      true ->
        with :ok <- Access.ensure_budget_state_dir() do
          Schema.add_runtime_turn_sandbox_roots(turn_sandbox_policy, [Access.budget_state_dir()])
        end
    end
  end
end
