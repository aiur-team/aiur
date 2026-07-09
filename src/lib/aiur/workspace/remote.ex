defmodule Aiur.Workspace.Remote do
  @moduledoc "SSH execution plumbing shared by every remote workspace clause: hard-timeout command runner, tilde-expanding shell assignment, escaping."

  alias Aiur.SSH

  @spec remote_shell_assign(String.t(), String.t()) :: String.t()
  def remote_shell_assign(variable_name, raw_path)
      when is_binary(variable_name) and is_binary(raw_path) do
    [
      "#{variable_name}=#{shell_escape(raw_path)}",
      "case \"$#{variable_name}\" in",
      "  '~') #{variable_name}=\"$HOME\" ;;",
      "  '~/'*) " <> variable_name <> "=\"$HOME/${" <> variable_name <> "#~/}\" ;;",
      "esac"
    ]
    |> Enum.join("\n")
  end

  @spec run_remote_command(String.t(), String.t(), pos_integer()) ::
          {:ok, {String.t(), non_neg_integer()}} | {:error, term()}
  def run_remote_command(worker_host, script, timeout_ms)
      when is_binary(worker_host) and is_binary(script) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:workspace_hook_timeout, "remote_command", timeout_ms}}
    end
  end

  @spec shell_escape(String.t()) :: String.t()
  def shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
