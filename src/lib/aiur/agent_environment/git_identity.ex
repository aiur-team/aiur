defmodule Aiur.AgentEnvironment.GitIdentity do
  @moduledoc """
  The git identity agent commits carry, and the workspace guards that keep AI
  attribution out of them (#4068).

  Without this an agent's `git commit` reads the operator's global git config,
  so fleet work is authored as the human running the daemon. `env/1` supplies
  `GIT_AUTHOR_*` / `GIT_COMMITTER_*`, which outrank every config file, to each
  backend through `Aiur.AgentEnvironment`.

  The identity is `agent.git_identity`, each unset field falling back to the
  `tracker.github.bot_account` login (`<login>@users.noreply.github.com`).
  With neither configured nothing is exported and git behaves as before.
  """

  require Logger

  alias Aiur.Config
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.Workspace.GitMetadata

  @hook_marker "aiur-attribution-guard"
  @claude_settings ".claude/settings.local.json"

  @hook """
  #!/bin/sh
  # #{@hook_marker}: installed by Aiur. Agent commits carry no AI attribution.
  if grep -Eiq '^co-authored-by:.*(claude|anthropic|codex|openai|chatgpt|copilot|gemini|cursor|opencode|deepseek|kimi)' "$1" ||
    grep -Eq '🤖|Generated with \\[?(Claude|Codex|OpenCode)' "$1"; then
    echo 'aiur: commit message carries AI attribution; remove the Co-Authored-By trailer / generated-with footer and commit again' >&2
    exit 1
  fi
  """

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

  @doc """
  Install the attribution guards into a local workspace: a `commit-msg` hook
  that rejects AI trailers and footers, and Claude Code settings that stop the
  CLI from adding them. Best-effort — a workspace that cannot take them still
  dispatches, because the identity itself travels in the environment.
  """
  # ponytail: local workspaces only, and the hook is skipped when the repo sets
  # `core.hooksPath` or ships its own commit-msg hook. Move the check into the
  # `git` guard (`priv/github_push_guard.sh`) if either gap starts to matter.
  @spec install(Path.t() | nil) :: :ok
  def install(workspace) when is_binary(workspace) do
    if File.dir?(Path.join(workspace, ".git")) do
      for {step, result} <- [hook: install_hook(workspace), claude_settings: install_claude_settings(workspace)], result != :ok do
        Logger.warning("agent attribution guard install failed workspace=#{workspace} step=#{step} reason=#{inspect(result)}")
      end
    end

    :ok
  end

  def install(_workspace), do: :ok

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

  defp install_hook(workspace) do
    path = Path.join(workspace, ".git/hooks/commit-msg")

    if writable_target?(path) and (not File.exists?(path) or ours?(path)) do
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(path, @hook),
           do: File.chmod(path, 0o755)
    else
      :ok
    end
  end

  defp ours?(path), do: File.read!(path) =~ @hook_marker

  # `includeCoAuthoredBy` is the key older CLIs read; `attribution` replaced it.
  defp install_claude_settings(workspace) do
    path = Path.join(workspace, @claude_settings)

    with true <- writable_target?(path) and not tracked?(workspace),
         {:ok, settings} <- read_settings(path),
         :ok <- GitMetadata.ensure_paths_excluded(workspace, [@claude_settings]),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      merged = Map.merge(settings, %{"includeCoAuthoredBy" => false, "attribution" => %{"commit" => "", "pr" => ""}})
      if merged == settings, do: :ok, else: File.write(path, Jason.encode!(merged, pretty: true) <> "\n")
    else
      # A tracked, symlinked or unparseable file belongs to the repository.
      false -> :ok
      :skip -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp read_settings(path) do
    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{} = settings} -> {:ok, settings}
          _other -> :skip
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, _reason} = error ->
        error
    end
  end

  # Never write through a symlink an agent could have planted in its workspace.
  defp writable_target?(path), do: not match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path))

  defp tracked?(workspace) do
    match?({_out, 0}, System.cmd("git", ["-C", workspace, "ls-files", "--error-unmatch", @claude_settings], stderr_to_stdout: true))
  rescue
    _git_unavailable -> false
  end
end
