defmodule Aiur.AgentCommandInstaller do
  @moduledoc false

  import Bitwise, only: [band: 2]

  alias Aiur.Fs
  alias Aiur.Workspace.Remote

  @spec bin_dir(Path.t(), Path.t()) :: Path.t()
  def bin_dir(workspace, relative_dir), do: Path.join(workspace, relative_dir)

  @spec install(Path.t(), Path.t(), [String.t()], String.t(), atom()) :: :ok | {:error, term()}
  def install(workspace, relative_dir, command_names, script, error_tag)
      when is_binary(workspace) and is_list(command_names) and is_binary(script) do
    bin_dir = bin_dir(workspace, relative_dir)

    with :ok <- ensure_directory(Path.join(workspace, ".aiur-runtime")),
         :ok <- ensure_directory(bin_dir) do
      install_commands(bin_dir, command_names, script, error_tag)
    end
  end

  @spec remote_install_script(Path.t(), Path.t(), [String.t()], String.t()) :: String.t()
  def remote_install_script(workspace, relative_dir, command_names, script)
      when is_binary(workspace) and is_list(command_names) and is_binary(script) do
    encoded = Base.encode64(script)
    commands = command_names |> Enum.map(&Aiur.Shell.escape/1) |> Enum.join(" ")

    [
      "set -eu",
      Remote.remote_shell_assign("workspace", workspace),
      "runtime=\"$workspace/.aiur-runtime\"",
      "bin=\"$workspace/#{relative_dir}\"",
      "if [ -L \"$runtime\" ] || [ -L \"$bin\" ]; then echo 'unsafe symlink in agent support path' >&2; exit 73; fi",
      "mkdir -p \"$bin\"",
      "source_tmp=\"$bin/.aiur-command-wrapper.$$\"",
      "trap 'rm -f \"$source_tmp\" \"${tmp:-}\"' EXIT HUP INT TERM",
      "(set -C; : > \"$source_tmp\")",
      "printf '%s' '#{encoded}' | base64 -d > \"$source_tmp\"",
      "chmod 755 \"$source_tmp\"",
      "for command_name in #{commands}; do",
      "  target=\"$bin/$command_name\"",
      "  if [ -L \"$target\" ] || { [ -e \"$target\" ] && [ ! -f \"$target\" ]; }; then",
      "    echo 'unsafe agent command target' >&2",
      "    exit 73",
      "  fi",
      "  if [ -f \"$target\" ] && [ -x \"$target\" ] && cmp -s \"$source_tmp\" \"$target\"; then continue; fi",
      "  tmp=\"$target.tmp.$$\"",
      "  (set -C; : > \"$tmp\")",
      "  cp \"$source_tmp\" \"$tmp\"",
      "  chmod 755 \"$tmp\"",
      "  mv -f \"$tmp\" \"$target\"",
      "  tmp=",
      "done",
      "rm -f \"$source_tmp\"",
      "trap - EXIT HUP INT TERM"
    ]
    |> Enum.join("\n")
  end

  defp install_commands(bin_dir, command_names, script, error_tag) do
    Enum.reduce_while(command_names, :ok, fn command_name, :ok ->
      case install_command(Path.join(bin_dir, command_name), script, error_tag) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp install_command(target, script, error_tag) do
    if current_executable?(target, script) do
      :ok
    else
      atomic_install(target, script, error_tag)
    end
  end

  defp current_executable?(target, script) do
    with {:ok, %File.Stat{type: :regular, mode: mode}} <- File.lstat(target),
         {:ok, ^script} <- File.read(target) do
      band(mode, 0o111) != 0
    else
      _other -> false
    end
  end

  defp ensure_directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, %File.Stat{type: type}} -> {:error, {:unsafe_agent_support_path, path, type}}
      {:error, :enoent} -> File.mkdir(path)
      {:error, reason} -> {:error, {:agent_support_path_unavailable, path, reason}}
    end
  end

  defp atomic_install(target, script, error_tag) do
    case Fs.atomic_write(target, script, mode: 0o755) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, {error_tag, target, reason}}
    end
  end
end
