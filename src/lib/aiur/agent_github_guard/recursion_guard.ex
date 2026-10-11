defmodule Aiur.AgentGitHubGuard.RecursionGuard do
  @moduledoc """
  Splices the shared recursion guard into the `gh` and `git` wrappers (#4205).

  Both wrappers resolve a "real" executable and exec it. When that executable
  leads back to the wrapper — a mis-set `PATH`, a fake that calls `git` — each
  hop spawns the next and the host runs out of processes. The guard lives in
  one snippet so the two wrappers cannot drift.
  """

  @snippet_path Path.expand("../../../priv/guard_recursion.sh", __DIR__)
  @external_resource @snippet_path
  @snippet File.read!(@snippet_path)
  @marker "# @aiur-recursion-guard@\n"

  @spec splice(String.t(), String.t()) :: String.t()
  def splice(script, tool) when is_binary(script) and tool in ["gh", "git"] do
    guard = @snippet |> String.replace("@TOOL@", String.upcase(tool)) |> String.replace("@tool@", tool)

    case String.split(script, @marker, parts: 2) do
      [head, tail] -> head <> guard <> tail
      [_unmarked] -> raise ArgumentError, "#{tool} guard script has no recursion-guard marker"
    end
  end
end
