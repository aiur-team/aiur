defmodule Aiur.AgentCLI do
  @moduledoc """
  Binds the worker's mandatory `aiur guard-pr-deletions` command to the
  daemon build that wrote the prompt, on both local and remote workers.
  """

  alias Aiur.AgentCommandInstaller

  @relative_bin_dir ".aiur-runtime/bin"
  @guard_path Path.expand("../../../packaging/npm/aiur-cli/libexec/guard-pr-deletions.sh", __DIR__)
  @external_resource @guard_path
  @guard File.read!(@guard_path)

  @wrapper """
  #!/usr/bin/env bash
  set -euo pipefail
  worker_bin="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  if [[ "${1:-}" == guard-pr-deletions ]]; then
    shift
    exec "$worker_bin/aiur-guard-pr-deletions" "$@"
  fi

  # Other CLI commands keep their normal meaning. Remove only this worker's
  # wrapper directory before resolving the next `aiur`, preventing recursion.
  remaining_path=
  IFS=: read -ra path_entries <<< "$PATH"
  for entry in "${path_entries[@]}"; do
    [[ "$entry" == "$worker_bin" ]] && continue
    remaining_path="${remaining_path:+$remaining_path:}$entry"
  done
  PATH="$remaining_path"
  export PATH
  next_aiur="$(command -v aiur || true)"
  if [[ -z "$next_aiur" ]]; then
    echo 'aiur: no other CLI is available for this worker command' >&2
    exit 127
  fi
  exec "$next_aiur" "$@"
  """

  @spec install(Path.t()) :: :ok | {:error, term()}
  def install(workspace) do
    with :ok <- AgentCommandInstaller.install(workspace, @relative_bin_dir, ["aiur"], @wrapper, :agent_cli_install_failed) do
      AgentCommandInstaller.install(workspace, @relative_bin_dir, ["aiur-guard-pr-deletions"], @guard, :agent_cli_install_failed)
    end
  end

  @spec remote_install_script(Path.t()) :: String.t()
  def remote_install_script(workspace) do
    AgentCommandInstaller.remote_install_script(workspace, @relative_bin_dir, ["aiur"], @wrapper) <>
      "\n" <>
      AgentCommandInstaller.remote_install_script(workspace, @relative_bin_dir, ["aiur-guard-pr-deletions"], @guard)
  end

  @spec missing_workspace_support(Path.t()) :: [String.t()]
  def missing_workspace_support(workspace) do
    for name <- ["aiur", "aiur-guard-pr-deletions"],
        path = Path.join(workspace, Path.join(@relative_bin_dir, name)),
        not executable_file?(path),
        do: Path.join(@relative_bin_dir, name)
  end

  defp executable_file?(path) do
    match?({:ok, %File.Stat{type: :regular, mode: mode}} when Bitwise.band(mode, 0o111) != 0, File.lstat(path))
  end
end
