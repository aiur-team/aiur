defmodule Aiur.SSH do
  @moduledoc false

  alias Aiur.Shell

  @spec run(String.t(), String.t(), keyword()) :: {:ok, {String.t(), non_neg_integer()}} | {:error, term()}
  def run(host, command, opts \\ []) when is_binary(host) and is_binary(command) do
    with {:ok, executable} <- ssh_executable() do
      {:ok, System.cmd(executable, ssh_args(host, command), opts)}
    end
  end

  @spec run_script(String.t(), String.t(), keyword()) :: {:ok, {String.t(), non_neg_integer()}} | {:error, term()}
  def run_script(host, script, opts \\ []) when is_binary(host) and is_binary(script) do
    with_script(host, script, opts, fn command -> command.() end)
  end

  @doc false
  @spec with_script(String.t(), String.t(), keyword(), ((-> term()) -> term())) :: term()
  def with_script(host, script, opts, fun)
      when is_binary(host) and is_binary(script) and is_list(opts) and is_function(fun, 1) do
    staged_script = temporary_script_path()

    with :ok <- stage_script(staged_script, script) do
      try do
        fun.(fn -> run_staged_script(host, staged_script, opts) end)
      after
        File.rm(staged_script)
      end
    end
  end

  @spec start_port(String.t(), String.t(), keyword()) :: {:ok, port()} | {:error, term()}
  def start_port(host, command, opts \\ []) when is_binary(host) and is_binary(command) do
    with {:ok, executable} <- ssh_executable() do
      line_bytes = Keyword.get(opts, :line)

      port_opts =
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: Enum.map(ssh_args(host, command), &String.to_charlist/1)
        ]
        |> maybe_put_line_option(line_bytes)

      {:ok, Port.open({:spawn_executable, String.to_charlist(executable)}, port_opts)}
    end
  end

  @spec remote_shell_command(String.t()) :: String.t()
  def remote_shell_command(command) when is_binary(command) do
    "bash -lc " <> Aiur.Shell.escape(command)
  end

  defp ssh_executable do
    case System.find_executable("ssh") do
      nil -> {:error, :ssh_not_found}
      executable -> {:ok, executable}
    end
  end

  defp temporary_script_path do
    suffix = :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
    Path.join(System.tmp_dir!(), "aiur-ssh-script-#{suffix}.sh")
  end

  defp stage_script(path, script) do
    case File.open(path, [:write, :binary, :exclusive], &IO.binwrite(&1, script)) do
      {:ok, :ok} ->
        case File.chmod(path, 0o600) do
          :ok -> :ok
          {:error, reason} -> cleanup_staging_failure(path, reason)
        end

      {:ok, {:error, reason}} ->
        cleanup_staging_failure(path, reason)

      {:error, reason} ->
        {:error, {:ssh_script_staging_failed, reason}}
    end
  end

  defp cleanup_staging_failure(path, reason) do
    File.rm(path)
    {:error, {:ssh_script_staging_failed, reason}}
  end

  defp run_staged_script(host, path, opts) do
    with {:ok, executable} <- ssh_executable(),
         shell when is_binary(shell) <- System.find_executable("sh") do
      command =
        [executable | ssh_script_args(host)]
        |> Enum.map_join(" ", &Shell.escape/1)
        |> Kernel.<>(" < #{Shell.escape(path)}")

      {:ok, System.cmd(shell, ["-c", command], opts)}
    else
      nil -> {:error, :shell_not_found}
      error -> error
    end
  end

  defp ssh_args(host, command) do
    ssh_target_args(host) ++ [remote_shell_command(command)]
  end

  defp ssh_script_args(host), do: ssh_target_args(host) ++ [remote_shell_command("bash -s")]

  defp ssh_target_args(host) do
    %{destination: destination, port: port} = parse_target(host)

    []
    |> maybe_put_config()
    |> Kernel.++(["-T"])
    |> maybe_put_port(port)
    |> Kernel.++([destination])
  end

  defp maybe_put_line_option(port_opts, nil), do: port_opts
  defp maybe_put_line_option(port_opts, line_bytes), do: Keyword.put(port_opts, :line, line_bytes)

  defp maybe_put_config(args) do
    case System.get_env("AIUR_SSH_CONFIG") do
      config_path when is_binary(config_path) and config_path != "" ->
        args ++ ["-F", config_path]

      _ ->
        args
    end
  end

  defp maybe_put_port(args, nil), do: args
  defp maybe_put_port(args, port), do: args ++ ["-p", port]

  defp parse_target(target) when is_binary(target) do
    trimmed_target = String.trim(target)

    # OpenSSH does not interpret bare "host:port" as "host + port"; it treats the
    # whole value as a hostname and leaves the port at 22. We split that shorthand
    # here so worker config can use "localhost:2222" without requiring ssh:// URIs.
    case Regex.run(~r/^(.*):(\d+)$/, trimmed_target, capture: :all_but_first) do
      [destination, port] ->
        if valid_port_destination?(destination) do
          %{destination: destination, port: port}
        else
          %{destination: trimmed_target, port: nil}
        end

      _ ->
        %{destination: trimmed_target, port: nil}
    end
  end

  defp valid_port_destination?(destination) when is_binary(destination) do
    destination != "" and
      (not String.contains?(destination, ":") or bracketed_host?(destination))
  end

  defp bracketed_host?(destination) when is_binary(destination) do
    # IPv6 literals contain ":" already, so we only accept additional ":port"
    # parsing when the host is explicitly bracketed, e.g. "[::1]:2222".
    String.contains?(destination, "[") and String.contains?(destination, "]")
  end
end
