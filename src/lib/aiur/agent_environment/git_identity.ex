defmodule Aiur.AgentEnvironment.GitIdentity do
  @moduledoc """
  The git identity agent commits carry (#4068).

  Without this an agent's `git commit` reads the operator's global git config,
  so fleet work is authored as the human running the daemon. `env/1` supplies
  `GIT_AUTHOR_*` / `GIT_COMMITTER_*`, which outrank every config file, to each
  backend through `Aiur.AgentEnvironment`.

  The identity is `agent.git_identity`, each unset field falling back to the
  `tracker.github.bot_account` login (`<login>@users.noreply.github.com`).
  With neither configured the neutral `Aiur Agent` identity is exported and a
  warning is logged once: the operator's identity is never the fallback.
  """

  require Logger

  alias Aiur.Config
  alias Aiur.GitHub.Config, as: GitHubConfig

  @neutral {"Aiur Agent", "aiur-agent@users.noreply.github.com"}

  @spec identity(keyword()) :: {String.t(), String.t()}
  def identity(opts \\ []) do
    case Keyword.get_lazy(opts, :git_identity, &configured/0) do
      {name, email} when is_binary(name) and is_binary(email) -> {name, email}
      _unset -> @neutral
    end
  end

  @doc "`GIT_AUTHOR_*` / `GIT_COMMITTER_*` pairs for the agent identity."
  @spec env(keyword()) :: [{String.t(), String.t()}]
  def env(opts \\ []) do
    {name, email} = identity(opts)
    [{"GIT_AUTHOR_NAME", name}, {"GIT_AUTHOR_EMAIL", email}, {"GIT_COMMITTER_NAME", name}, {"GIT_COMMITTER_EMAIL", email}]
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
  @spec resolve(map() | nil, String.t() | nil) :: {String.t(), String.t()}
  def resolve(configured, login) do
    {neutral_name, neutral_email} = @neutral

    {field(configured, :name) || login || neutral_name, field(configured, :email) || (login && "#{login}@users.noreply.github.com") || neutral_email}
  end

  defp configured do
    identity = resolve(Config.settings!().agent.git_identity, GitHubConfig.bot_account())
    if identity == @neutral, do: warn_neutral_once()
    identity
  rescue
    _config_unavailable -> nil
  catch
    :exit, _reason -> nil
  end

  defp warn_neutral_once do
    if :persistent_term.get({__MODULE__, :warned}, false) == false do
      :persistent_term.put({__MODULE__, :warned}, true)

      Logger.warning(
        "agent_git_identity=neutral reason=unconfigured agent commits are authored as Aiur Agent; " <>
          "set agent.git_identity or tracker.github.bot_account"
      )
    end
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
