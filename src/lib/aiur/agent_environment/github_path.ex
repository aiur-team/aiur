defmodule Aiur.AgentEnvironment.GitHubPath do
  @moduledoc false

  alias Aiur.AgentGitHubGuard

  @spec port_env(Path.t()) :: [{charlist(), charlist()}]
  def port_env(workspace) do
    path =
      [AgentGitHubGuard.bin_dir(workspace), System.get_env("PATH", "")]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(":")

    [{~c"PATH", String.to_charlist(path)}]
  end

  @spec shell_export(Path.t()) :: String.t()
  def shell_export(workspace), do: "PATH=#{Aiur.Shell.escape(AgentGitHubGuard.bin_dir(workspace))}${PATH:+:$PATH}; export PATH\n"
end
