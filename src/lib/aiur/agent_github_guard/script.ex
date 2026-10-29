defmodule Aiur.AgentGitHubGuard.Script do
  @moduledoc """
  Assembles the agent `gh` and `git` guards from their source fragments.

  Each guard is one shell script, kept under `priv/github_guard/<guard>/` as
  ordered fragments so every control is reviewable on its own. The fragments
  are concatenated at compile time and installed as one file: the guard decides
  agent context from its own install directory. The `gh` deadline launcher
  streams its assembled body through an anonymous pipe, keeping agent-writable
  paths outside the code execution boundary. A fragment is not a valid script
  alone and is never run alone.

  The first line of every fragment is a header naming the assembled guard. It
  is dropped during assembly; a fragment without it fails compilation.
  """

  alias Aiur.GitHub.Access.WrapperSource

  @root Path.expand("../../../priv/github_guard", __DIR__)
  # `.claude/hooks/issue-disposition.py` assembles the `gh` guard from the same
  # directory in file-name order, so list order and name order must agree.
  @parts [
    git: ~w(00-destructive 10-worktree-push)
  ]

  @paths for {guard, names} <- @parts, do: {guard, Enum.map(names, &Path.join([@root, "#{guard}", &1 <> ".sh"]))}
  for {_guard, paths} <- @paths, path <- paths, do: @external_resource(path)

  @sources (for {guard, paths} <- @paths do
              header = "# Fragment of the assembled `#{guard}` guard (Aiur.AgentGitHubGuard.Script); not a standalone script.\n"

              source =
                Enum.map_join(paths, fn path ->
                  fragment = File.read!(path)
                  String.starts_with?(fragment, header) || raise "#{path} must start with #{inspect(header)}"
                  String.replace_prefix(fragment, header, "")
                end)

              {guard, source}
            end)

  @doc "The assembled `gh` guard."
  @spec gh() :: String.t()
  defdelegate gh, to: WrapperSource, as: :aiur

  @doc "The assembled `git` guard."
  @spec git() :: String.t()
  def git, do: @sources[:git]

  @doc "The fragment files of each guard, in assembly order."
  @spec paths() :: keyword([Path.t()])
  def paths, do: [gh: WrapperSource.paths()] ++ @paths
end
