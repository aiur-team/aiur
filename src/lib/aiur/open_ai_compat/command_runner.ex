defmodule Aiur.OpenAICompat.CommandRunner do
  @moduledoc false

  @timeout_ms 300_000

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
        credential_unsets(),
        "--ro-bind",
        "/",
        "/",
        "--bind",
        workspace,
        workspace,
        "--chdir",
        workspace,
        "--tmpfs",
        "/tmp",
        "--",
        "/bin/bash",
        "-lc",
        command
      ]
      |> List.flatten()

    task = Task.async(fn -> runner.(executable, args, stderr_to_stdout: true) end)

    case Task.yield(task, @timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, exit_code}} -> %{"success" => exit_code == 0, "output" => truncate(output), "exit_code" => exit_code}
      _ -> failure("command timed out")
    end
  rescue
    error -> failure("command failed: #{Exception.message(error)}")
  end

  defp failure(message), do: %{"success" => false, "output" => message, "exit_code" => nil}
  defp credential_unsets, do: Enum.flat_map(Aiur.AgentEnvironment.provider_credential_env_names(), &["--unsetenv", &1])
  defp truncate(output) when byte_size(output) <= 100_000, do: output
  defp truncate(output), do: binary_part(output, 0, 100_000) <> "\n[output truncated]"
end
