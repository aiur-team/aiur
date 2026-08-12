defmodule Aiur.OpenAICompat.CommandRunner do
  @moduledoc false

  alias Aiur.{AgentBuildGuard, AgentEnvironment, AgentGitHubGuard, BuildGate}

  @timeout_ms 300_000
  @inherited_env_names ~w(GITHUB_TOKEN GH_TOKEN LANG LC_ALL TERM)
  @system_roots ~w(/usr)
  @system_files ~w(
    /etc/ca-certificates
    /etc/gitconfig
    /etc/group
    /etc/hosts
    /etc/localtime
    /etc/nsswitch.conf
    /etc/passwd
    /etc/resolv.conf
    /etc/ssl
  )

  @spec run(Path.t(), String.t(), keyword()) :: map()
  def run(workspace, command, opts \\ []) when is_binary(workspace) and is_binary(command) do
    runner = Keyword.get(opts, :system_cmd, &System.cmd/3)

    case Keyword.get(opts, :sandbox_executable, System.find_executable("bwrap")) do
      executable when is_binary(executable) -> run_sandboxed(executable, workspace, command, runner)
      _ -> failure("command sandbox unavailable; install bubblewrap to enable exec_command")
    end
  end

  defp run_sandboxed(executable, workspace, command, runner) do
    args =
      [
        "--die-with-parent",
        "--unshare-all",
        "--share-net",
        environment_args(workspace),
        "--tmpfs",
        "/tmp",
        base_filesystem_args(workspace),
        "--bind",
        workspace,
        workspace,
        "--chdir",
        workspace,
        "--",
        "/bin/bash",
        "-c",
        command
      ]
      |> List.flatten()

    task =
      Task.Supervisor.async_nolink(Aiur.TaskSupervisor, fn ->
        runner.(executable, args, stderr_to_stdout: true)
      end)

    case Task.yield(task, @timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, exit_code}} -> %{"success" => exit_code == 0, "output" => truncate(output), "exit_code" => exit_code}
      {:exit, _reason} -> failure("command runner failed")
      _ -> failure("command timed out")
    end
  rescue
    error -> failure("command failed: #{Exception.message(error)}")
  end

  defp failure(message), do: %{"success" => false, "output" => message, "exit_code" => nil}

  defp environment_args(workspace) do
    command_env =
      [
        {"HOME", workspace},
        {"TMPDIR", "/tmp"},
        {"MISE_DATA_DIR", "/opt/aiur-mise"},
        {"PATH", guarded_path(workspace)}
      ] ++ git_identity_env() ++ agent_environment(workspace)

    inherited =
      @inherited_env_names
      |> Enum.flat_map(fn name ->
        case System.get_env(name) do
          value when is_binary(value) and value != "" -> [{name, value}]
          _ -> []
        end
      end)

    ["--clearenv" | Enum.flat_map(command_env ++ inherited, fn {name, value} -> ["--setenv", name, value] end)]
  end

  defp base_filesystem_args(workspace) do
    [
      parent_directory_args(workspace),
      "--dir",
      "/etc",
      "--dir",
      "/opt",
      "--dir",
      "/opt/aiur-mise",
      Enum.flat_map(existing(@system_roots), &["--ro-bind", &1, &1]),
      Enum.flat_map(existing(@system_files), &["--ro-bind", &1, &1]),
      mise_mount_args(),
      build_gate_mount_args(),
      system_link_args(),
      "--proc",
      "/proc",
      "--dev",
      "/dev"
    ]
  end

  defp parent_directory_args(workspace) do
    workspace
    |> Path.dirname()
    |> Path.split()
    |> Enum.reject(&(&1 == "/"))
    |> Enum.map_reduce("", fn component, parent ->
      path = Path.join("/" <> parent, component)
      {path, String.trim_leading(path, "/")}
    end)
    |> elem(0)
    |> Enum.flat_map(&["--dir", &1])
  end

  defp mise_mount_args do
    installs = Path.join(mise_data_dir(), "installs")
    if File.dir?(installs), do: ["--ro-bind", installs, "/opt/aiur-mise/installs"], else: []
  end

  defp build_gate_mount_args do
    env = Map.new(BuildGate.shell_env())
    hook_path = env["BASH_ENV"]

    [
      bind_if_present(env["AIUR_BUILD_GATE_DIR"], :writable),
      bind_if_present(env["AIUR_BUILD_GATE_LOCK_DIR"], :read_only),
      bind_if_present(if(is_binary(hook_path), do: Path.dirname(hook_path)), :read_only)
    ]
  end

  defp bind_if_present(path, mode) when is_binary(path) do
    if File.exists?(path) do
      flag = if mode == :writable, do: "--bind", else: "--ro-bind"
      [parent_directory_args(path), flag, path, path]
    else
      []
    end
  end

  defp bind_if_present(_path, _mode), do: []

  defp system_link_args do
    Enum.flat_map(~w(/bin /lib /lib64), &system_link_arg/1)
  end

  defp system_link_arg(path) do
    case File.read_link(path) do
      {:ok, target} -> ["--symlink", target, path]
      {:error, _reason} -> read_only_bind(path)
    end
  end

  defp read_only_bind(path) do
    if File.dir?(path), do: ["--ro-bind", path, path], else: []
  end

  defp agent_environment(workspace) do
    workspace
    |> AgentEnvironment.workspace_env()
    |> Enum.flat_map(fn
      {name, value} when is_list(name) and is_list(value) -> [{to_string(name), to_string(value)}]
      _unset -> []
    end)
  end

  defp sandbox_path do
    install_prefix = Path.join(mise_data_dir(), "installs")

    System.get_env("PATH", "")
    |> String.split(":", trim: true)
    |> Enum.flat_map(fn path ->
      cond do
        path == install_prefix -> ["/opt/aiur-mise/installs"]
        String.starts_with?(path, install_prefix <> "/") -> [String.replace_prefix(path, install_prefix, "/opt/aiur-mise/installs")]
        String.starts_with?(path, "/usr/") or path in ["/usr", "/bin"] -> [path]
        true -> []
      end
    end)
    |> Kernel.++(["/usr/local/bin", "/usr/bin", "/bin"])
    |> Enum.uniq()
    |> Enum.join(":")
  end

  defp guarded_path(workspace) do
    [AgentBuildGuard.bin_dir(workspace), AgentGitHubGuard.bin_dir(workspace), sandbox_path()]
    |> Enum.join(":")
  end

  defp mise_data_dir do
    System.get_env("MISE_DATA_DIR") || Path.join(System.user_home!(), ".local/share/mise")
  end

  defp git_identity_env do
    name = System.get_env("GIT_AUTHOR_NAME") || global_git_config("user.name") || "Aiur Agent"
    email = System.get_env("GIT_AUTHOR_EMAIL") || global_git_config("user.email") || "aiur-agent@users.noreply.github.com"

    [
      {"GIT_AUTHOR_NAME", name},
      {"GIT_AUTHOR_EMAIL", email},
      {"GIT_COMMITTER_NAME", name},
      {"GIT_COMMITTER_EMAIL", email}
    ]
  end

  defp global_git_config(key) do
    case System.cmd("git", ["config", "--global", "--get", key], stderr_to_stdout: true) do
      {value, 0} -> String.trim(value)
      _ -> nil
    end
  rescue
    _error -> nil
  end

  defp existing(paths), do: Enum.filter(paths, &File.exists?/1)
  defp truncate(output) when byte_size(output) <= 100_000, do: output
  defp truncate(output), do: binary_part(output, 0, 100_000) <> "\n[output truncated]"
end
