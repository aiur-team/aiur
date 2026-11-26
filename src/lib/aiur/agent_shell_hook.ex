defmodule Aiur.AgentShellHook do
  @moduledoc false

  alias Aiur.BuildGate
  alias Aiur.BuildGate.HookSnapshot

  @spec port_env([{String.t(), String.t()}]) :: [{charlist(), charlist()}]
  def port_env(build_gate_env) do
    build_gate_hook =
      case List.keyfind(build_gate_env, "BASH_ENV", 0) do
        {"BASH_ENV", path} -> path
        nil -> nil
      end

    case HookSnapshot.ensure_file(hook_source(), Path.join(BuildGate.gate_dir(), ".agent-shell-hooks"), "agent_shell_environment.bash") do
      {:ok, hook} ->
        [{~c"BASH_ENV", String.to_charlist(hook)}] ++
          if(is_binary(build_gate_hook), do: [{~c"AIUR_BUILD_GATE_HOOK", String.to_charlist(build_gate_hook)}], else: [])

      {:error, reason} ->
        raise "agent shell hook unavailable: #{inspect(reason)}"
    end
  end

  defp hook_source do
    :aiur
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("agent_shell_environment.bash")
  end
end
