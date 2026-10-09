defmodule Aiur.GitHub.Budget.SandboxRoots do
  @moduledoc false
  @behaviour Aiur.Config.TurnSandboxRoots

  alias Aiur.GitHub.Budget
  alias Aiur.Config.Schema

  @impl true
  def contribute(turn_sandbox_policy, _settings, opts) do
    cond do
      Keyword.get(opts, :remote, false) ->
        {:ok, turn_sandbox_policy}

      not Schema.workspace_write_policy?(turn_sandbox_policy) ->
        {:ok, turn_sandbox_policy}

      not Budget.enabled?() ->
        {:ok, turn_sandbox_policy}

      true ->
        with :ok <- Budget.ensure_state_dir() do
          Schema.add_runtime_turn_sandbox_roots(turn_sandbox_policy, [Budget.state_dir()])
        end
    end
  end
end
