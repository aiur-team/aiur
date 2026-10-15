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
  # #{@hook_marker}: installed by Aiur. Strip generated attribution, preserving human co-authors.
  tmp="$1.aiur-tmp.$$"
  trap 'rm -f "$tmp"' EXIT HUP INT TERM
  awk '
    BEGIN { IGNORECASE = 1 }
    /^co-authored-by:/ {
      line = tolower($0)
      if (line ~ /(claude|anthropic|codex|openai|chatgpt|copilot|gemini|cursor|opencode|deepseek|kimi|noreply@anthropic\.com)/) next
    }
    /generated with/ || /claude\.ai/ || /claude code session/ { next }
    { print }
  ' "$1" > "$tmp"
  cat "$tmp" > "$1"
  rm -f "$tmp"
  trap - EXIT HUP INT TERM
  """

  @pre_push_hook """
  #!/bin/sh
  # #{@push_marker}: installed by Aiur. Refuse commits with AI attribution.
  zero=0000000000000000000000000000000000000000
  while read local_ref local_sha remote_ref remote_sha || [ -n "${local_sha:-}" ]; do
    [ "$local_sha" = "$zero" ] && continue
    if [ "$remote_sha" = "$zero" ]; then range="$local_sha"; else range="$remote_sha..$local_sha"; fi
    for commit in $(git rev-list "$range" 2>/dev/null); do
      if git show -s --format=%B "$commit" | grep -Eiq '^co-authored-by:.*(claude|anthropic|codex|openai|chatgpt|copilot|gemini|cursor|opencode|deepseek|kimi|noreply@anthropic\.com)' || git show -s --format=%B "$commit" | grep -Eiq 'generated with|claude\.ai|claude code session'; then
        subject=$(git show -s --format=%s "$commit")
        echo "aiur: refusing to push commit $commit ($subject): AI attribution remains in the commit message" >&2
        exit 1
      fi
    done
  done
  exit 0
  """

  @doc """
  Install the attribution guards into a local workspace: a `commit-msg` hook
  that strips AI attribution, a `pre-push` hook that names offending commits,
  and Claude Code settings that stop the CLI from adding them. Best-effort — a workspace that cannot take them still
  dispatches, because the identity itself travels in the environment.
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

    if writable_target?(path) and (not File.exists?(path) or ours?(path)) do
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(path, @hook),
           do: File.chmod(path, 0o755)
    else
      :ok
    end
  end

  defp install_pre_push_hook(workspace) do
    path = Path.join(workspace, ".git/hooks/pre-push")

    if writable_target?(path) and (not File.exists?(path) or File.read!(path) =~ @push_marker) do
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(path, @pre_push_hook),
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
