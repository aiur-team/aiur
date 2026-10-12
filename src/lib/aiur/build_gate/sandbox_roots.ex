defmodule Aiur.BuildGate.SandboxRoots do
  @moduledoc false
  @behaviour Aiur.Config.TurnSandboxRoots

  alias Aiur.BuildGate
  alias Aiur.Config.Schema

  @impl true
  def contribute(turn_sandbox_policy, settings, opts) do
    gate_opts = [
      slots: settings.agent.max_concurrent_builds,
      stagger_seconds: settings.agent.build_start_stagger_seconds,
      min_free_memory_mb: settings.agent.min_free_memory_mb
    ]

    cond do
      Keyword.get(opts, :remote, false) ->
        {:ok, turn_sandbox_policy}

      not BuildGate.enabled?(gate_opts) ->
        {:ok, turn_sandbox_policy}

      not Schema.workspace_write_policy?(turn_sandbox_policy) ->
        {:ok, turn_sandbox_policy}

      true ->
        with {:ok, effective_roots} <- Schema.policy_writable_roots(turn_sandbox_policy),
             {:ok, gate_dir} <-
               BuildGate.prepare_writable_root(Keyword.put(gate_opts, :writable_roots, effective_roots)) do
          Schema.add_runtime_turn_sandbox_roots(turn_sandbox_policy, [gate_dir])
        end
    end
  end
end
