defmodule Aiur.AgentEnvironment.GitIdentity do
  @moduledoc """
  The git identity agent commits carry (#4068).

  Without this an agent's `git commit` reads the operator's global git config,
  so fleet work is authored as the human running the daemon. `env/1` supplies
  `GIT_AUTHOR_*` / `GIT_COMMITTER_*`, which outrank every config file, to each
  backend through `Aiur.AgentEnvironment`.

  The identity is `agent.git_identity`, each unset field falling back to the
  `tracker.github.bot_account` login (`<login>@users.noreply.github.com`).
  With neither configured nothing is exported and git behaves as before.
  """

  alias Aiur.Config
  alias Aiur.GitHub.Config, as: GitHubConfig

  @spec identity(keyword()) :: {String.t(), String.t()} | nil
  def identity(opts \\ []) do
    case Keyword.get_lazy(opts, :git_identity, &configured/0) do
      {name, email} when is_binary(name) and is_binary(email) -> {name, email}
      _unset -> nil
    end
  end

  @doc "`GIT_AUTHOR_*` / `GIT_COMMITTER_*` pairs, or `[]` when no identity is configured."
  @spec env(keyword()) :: [{String.t(), String.t()}]
  def env(opts \\ []) do
    case identity(opts) do
      {name, email} ->
        [{"GIT_AUTHOR_NAME", name}, {"GIT_AUTHOR_EMAIL", email}, {"GIT_COMMITTER_NAME", name}, {"GIT_COMMITTER_EMAIL", email}]

      nil ->
        []
    end
  end

  @doc "`env/1` as `Port.open` charlist tuples."
  @spec port_env(keyword()) :: [{charlist(), charlist()}]
  def port_env(opts \\ []) do
    Enum.map(env(opts), fn {name, value} -> {String.to_charlist(name), String.to_charlist(value)} end)
  end

  @doc "`env/1` as shell `export` lines for launch paths that have no `env:` option."
  @spec export_prefix(keyword()) :: String.t()
  def export_prefix(opts \\ []) do
    Enum.map_join(env(opts), fn {name, value} -> "export #{name}=#{Aiur.Shell.escape(value)}\n" end)
  end

  @doc false
  @spec resolve(map() | nil, String.t() | nil) :: {String.t() | nil, String.t() | nil}
  def resolve(configured, login) do
    {field(configured, :name) || login, field(configured, :email) || (login && "#{login}@users.noreply.github.com")}
  end

  defp configured do
    resolve(Config.settings!().agent.git_identity, GitHubConfig.bot_account())
  rescue
    _config_unavailable -> nil
  catch
    :exit, _reason -> nil
  end

  defp field(configured, key) do
    with value when is_binary(value) <- configured && Map.get(configured, key),
         trimmed when trimmed != "" <- String.trim(value) do
      trimmed
    else
      _unset -> nil
    end
  end
end
