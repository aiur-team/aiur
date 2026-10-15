defmodule Aiur.Workspace.AttributionGuard do
  @moduledoc """
  Workspace guards that keep AI attribution out of agent commits (#4068): a
  `commit-msg` hook that strips generated attribution, a `pre-push` check, and
  Claude Code settings that stop the CLI adding its trailer. The commit identity
  itself is `Aiur.AgentEnvironment.GitIdentity`.
  """

  require Logger

  alias Aiur.Workspace.GitMetadata

  @hook_marker "aiur-attribution-guard"
  @push_marker "aiur-attribution-pre-push"
  @claude_settings ".claude/settings.local.json"

  @hook """
  #!/bin/sh
  # #{@hook_marker}: strip generated AI attribution while retaining human co-authors.
  tmp="$1.aiur-tmp.$$"
  trap 'rm -f "$tmp"' EXIT HUP INT TERM
  awk '
    {
      lower = tolower($0)
      if (lower ~ /^co-authored-by:/ && lower ~ /(claude|anthropic|codex|openai|chatgpt|copilot|gemini|cursor|opencode|deepseek|kimi|noreply@anthropic[.]com)/) next
      if ((index(lower, "generated with") == 1 || index(lower, "🤖 generated with") == 1) && lower ~ /(claude|codex|opencode)/) next
      if (index(lower, "https://claude.ai/code/session_") == 1 || lower ~ /^claude code session/) next
      print
    }
  ' "$1" > "$tmp"
  cat "$tmp" > "$1"
  rm -f "$tmp"
  trap - EXIT HUP INT TERM
  if [ -x "$0.aiur-original" ]; then
    "$0.aiur-original" "$1"
  fi
  """

  @pre_push_hook """
  #!/bin/sh
  # #{@push_marker}: installed by Aiur. Refuse commits with AI attribution.
  zero=0000000000000000000000000000000000000000
  updates="$0.aiur-updates.$$"
  trap 'rm -f "$updates"' EXIT HUP INT TERM
  cat > "$updates"
  while read local_ref local_sha remote_ref remote_sha || [ -n "${local_sha:-}" ]; do
    [ "$local_sha" = "$zero" ] && continue
    if [ "$remote_sha" = "$zero" ]; then range="$local_sha"; else range="$remote_sha..$local_sha"; fi
    for commit in $(git rev-list "$range" 2>/dev/null); do
      if git show -s --format=%B "$commit" | awk '
        {
          line = tolower($0)
          if (line ~ /^co-authored-by:/ && line ~ /(claude|anthropic|codex|openai|chatgpt|copilot|gemini|cursor|opencode|deepseek|kimi|noreply@anthropic[.]com)/) found = 1
          if ((index(line, "generated with") == 1 || index(line, "🤖 generated with") == 1) && line ~ /(claude|codex|opencode)/) found = 1
          if (index(line, "https://claude.ai/code/session_") == 1 || line ~ /^claude code session/) found = 1
        }
        END { exit !found }
      '; then
        subject=$(git show -s --format=%s "$commit")
        echo "aiur: refusing to push commit $commit ($subject): AI attribution remains in the commit message" >&2
        exit 1
      fi
    done
  done < "$updates"
  if [ -x "$0.aiur-original" ]; then
    "$0.aiur-original" < "$updates"
  fi
  exit 0
  """

  @doc """
  Install the attribution guards into a local workspace: a `commit-msg` hook
  that strips AI attribution, a `pre-push` hook that names offending commits,
  and Claude Code settings that stop the CLI from adding attribution. Existing
  Git hooks are preserved and chained. Installation is best-effort because the
  commit identity also travels in the agent environment.
  """
  @spec install(Path.t() | nil) :: :ok
  def install(workspace) when is_binary(workspace) do
    if File.dir?(Path.join(workspace, ".git")) do
      for {step, result} <- [
            hook: install_hook(workspace),
            pre_push: install_pre_push_hook(workspace),
            claude_settings: install_claude_settings(workspace)
          ],
          result != :ok do
        Logger.warning("agent attribution guard install failed workspace=#{workspace} step=#{step} reason=#{inspect(result)}")
      end
    end

    :ok
  end

  def install(_workspace), do: :ok

  defp install_hook(workspace) do
    path = Path.join(workspace, ".git/hooks/commit-msg")
    install_managed_hook(path, @hook_marker, @hook)
  end

  defp install_pre_push_hook(workspace) do
    path = Path.join(workspace, ".git/hooks/pre-push")
    install_managed_hook(path, @push_marker, @pre_push_hook)
  end

  defp install_managed_hook(path, marker, contents) do
    backup = path <> ".aiur-original"

    with true <- writable_target?(path),
         :ok <- preserve_existing_hook(path, backup, marker),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, contents),
         :ok <- File.chmod(path, 0o755) do
      :ok
    else
      false -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp preserve_existing_hook(path, backup, marker) do
    cond do
      not File.exists?(path) -> :ok
      match?({:ok, _}, File.read(path)) and File.read!(path) =~ marker -> :ok
      File.exists?(backup) -> {:error, {:existing_hook_backup_present, backup}}
      true -> File.rename(path, backup)
    end
  end

  # `includeCoAuthoredBy` is the key older CLIs read; `attribution` replaced it.
  defp install_claude_settings(workspace) do
    path = Path.join(workspace, @claude_settings)

    with true <- writable_target?(path) and not tracked?(workspace),
         {:ok, settings} <- read_settings(path),
         :ok <- GitMetadata.ensure_paths_excluded(workspace, [@claude_settings]),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      merged =
        Map.merge(settings, %{
          "includeCoAuthoredBy" => false,
          "attribution" => %{"commit" => "", "pr" => ""}
        })

      if merged == settings,
        do: :ok,
        else: File.write(path, Jason.encode!(merged, pretty: true) <> "\n")
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
    match?(
      {_out, 0},
      System.cmd("git", ["-C", workspace, "ls-files", "--error-unmatch", @claude_settings], stderr_to_stdout: true)
    )
  rescue
    _git_unavailable -> false
  end
end
