defmodule Aiur.GitHub.Access.WrapperSource do
  @moduledoc "Compile-time composition of the mandatory Aiur GitHub policy and shared core."
  @root Path.expand("../../../../priv/github_guard", __DIR__)
  @manifest Path.join(@root, "parts.tsv")
  @external_resource @manifest
  @entries @manifest |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&String.split/1)
  @paths Enum.map(@entries, fn
           [group, name] when group in ["core", "aiur-policy"] -> Path.join([@root, "gh", name])
           entry -> raise "invalid GitHub guard part: #{inspect(entry)}"
         end)
  for path <- @paths, do: @external_resource(path)

  @source Enum.map_join(@paths, fn path ->
            header = "# Fragment of the assembled `gh` guard (Aiur.AgentGitHubGuard.Script); not a standalone script.\n"
            fragment = File.read!(path)
            String.starts_with?(fragment, header) || raise "invalid GitHub guard header: #{path}"
            String.replace_prefix(fragment, header, "")
          end)

  @spec aiur() :: String.t()
  def aiur, do: @source

  @spec paths() :: [Path.t()]
  def paths, do: @paths
end
