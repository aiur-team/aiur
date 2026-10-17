defmodule Aiur.TestGit do
  @moduledoc """
  Runs fixture `git` isolated from host and runner configuration.

  A fixture `git commit` must not block on a global hook, GPG signing, an
  editor or auto-maintenance (#4889). Callers set their own identity.
  """

  @config ~w(-c commit.gpgsign=false -c tag.gpgsign=false -c core.hooksPath=/dev/null -c gc.auto=0 -c maintenance.auto=false)
  @env [
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_CONFIG_NOSYSTEM", "1"},
    {"GIT_EDITOR", "true"},
    {"GIT_TERMINAL_PROMPT", "0"}
  ]

  @doc "The real git binary; inside an agent workspace PATH resolves `git` to the guard."
  @spec executable() :: String.t()
  def executable, do: System.get_env("AIUR_REAL_GIT") || System.find_executable("git")

  @doc "Runs isolated git with `args`, returning `{output, status}` with stderr merged."
  @spec cmd([String.t()], keyword()) :: {String.t(), non_neg_integer()}
  def cmd(args, opts \\ []) do
    {env, opts} = Keyword.pop(opts, :env, [])
    System.cmd(executable(), @config ++ args, [stderr_to_stdout: true, env: @env ++ env] ++ opts)
  end
end
