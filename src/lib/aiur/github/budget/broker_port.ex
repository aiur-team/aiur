defmodule Aiur.GitHub.Budget.BrokerPort do
  @moduledoc false

  alias Aiur.GitHub.{Budget, BudgetBroker}
  alias Aiur.GitHub.Budget.Settings
  require Logger

  @command_cleanup_ms 25

  @spec command([String.t()], String.t(), keyword()) :: term()
  def command(args, key, opts) when is_binary(key) do
    with true <- Budget.enabled?(opts),
         python when is_binary(python) <- Keyword.get(opts, :python, python_executable(opts)) do
      token_args =
        if Keyword.get(opts, :include_token_key, true) do
          ["--db", Budget.database_path(opts), "--token-key", key]
        else
          # `usage` spans every credential the broker has seen, so it takes no
          # token key (the broker command refuses one).
          ["--db", Budget.database_path(opts)]
        end

      identity_args =
        case Keyword.get(opts, :credential_key) do
          identity_key when is_binary(identity_key) and identity_key != "" -> ["--identity-key", identity_key]
          _missing -> []
        end

      command_args = [Budget.broker_path(opts) | args] ++ token_args ++ identity_args

      case broker_command(python, command_args, Settings.command_deadline(opts), opts) do
        {:ok, output, 0} -> {:ok, output}
        {:ok, output, status} -> broker_unavailable(status, output)
        {:error, reason} -> broker_unavailable(:exception, inspect(reason))
        :timeout -> broker_timeout()
      end
    else
      _unavailable -> :bypass
    end
  rescue
    error -> broker_unavailable(:exception, Exception.message(error))
  end

  defp broker_command(python, [broker | args] = command_args, deadline_at, opts) do
    # Explicit injection retains the one-shot path; production uses the resident broker.
    server = Keyword.get(opts, :broker_server, BudgetBroker)

    if (Keyword.has_key?(opts, :broker_server) || Process.whereis(BudgetBroker)) && not Keyword.has_key?(opts, :broker_path) && python == System.find_executable("python3") do
      BudgetBroker.command(server, broker, args, deadline_at)
    else
      port_command(python, command_args, deadline_at, Keyword.get(opts, :kill_fun))
    end
  end

  defp port_command(executable, args, deadline_at, kill_fun) do
    remaining_ms = max(deadline_at - System.monotonic_time(:millisecond), 0)

    if remaining_ms == 0 do
      :timeout
    else
      caller = self()
      result_ref = Process.alias()

      {guardian, guardian_ref} =
        spawn_monitor(fn ->
          result = owned_port_command(caller, executable, args, deadline_at, kill_fun)
          send(result_ref, {result_ref, self(), result})
        end)

      receive do
        {^result_ref, ^guardian, result} ->
          Process.unalias(result_ref) && Process.demonitor(guardian_ref, [:flush])
          result

        {:DOWN, ^guardian_ref, :process, ^guardian, reason} ->
          {:error, reason}
      after
        remaining_ms ->
          Process.unalias(result_ref)

          receive do
            {^result_ref, ^guardian, result} ->
              Process.demonitor(guardian_ref, [:flush])
              result

            {:DOWN, ^guardian_ref, :process, ^guardian, reason} ->
              {:error, reason}
          after
            0 ->
              Process.demonitor(guardian_ref, [:flush])
              :timeout
          end
      end
    end
  end

  defp owned_port_command(caller, executable, args, deadline_at, kill_fun) do
    caller_ref = Process.monitor(caller)

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [:binary, :exit_status, :stderr_to_stdout, :use_stdio, args: Enum.map(args, &String.to_charlist/1)]
      )

    await_port(port, caller, caller_ref, deadline_at, [], kill_fun)
  end

  defp await_port(port, caller, caller_ref, deadline_at, output, kill_fun) do
    remaining_ms = max(deadline_at - System.monotonic_time(:millisecond) - @command_cleanup_ms, 0)

    receive do
      {^port, {:data, data}} ->
        await_port(port, caller, caller_ref, deadline_at, [data | output], kill_fun)

      {^port, {:exit_status, status}} ->
        Process.demonitor(caller_ref, [:flush])
        {:ok, output |> Enum.reverse() |> IO.iodata_to_binary(), status}

      {:DOWN, ^caller_ref, :process, ^caller, _reason} ->
        terminate_port(port, min(deadline_at, System.monotonic_time(:millisecond) + @command_cleanup_ms), kill_fun)
        :timeout
    after
      remaining_ms ->
        Process.demonitor(caller_ref, [:flush])
        terminate_port(port, deadline_at, kill_fun)
        :timeout
    end
  end

  defp terminate_port(port, deadline_at, kill_fun) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> if is_function(kill_fun, 1), do: kill_fun.(os_pid), else: System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
      nil -> :ok
    end

    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      max(deadline_at - System.monotonic_time(:millisecond), 0) -> :ok
    end

    if Port.info(port), do: Port.close(port)
    flush_port(port)
  rescue
    ArgumentError -> :ok
  end

  defp flush_port(port) do
    receive do
      {^port, _message} -> flush_port(port)
    after
      0 -> :ok
    end
  end

  defp broker_unavailable(status, output) do
    Logger.warning("github_budget_broker_unavailable status=#{inspect(status)} output=#{inspect(String.trim(output))}")
    {:error, :github_budget_broker_unavailable}
  end

  defp broker_timeout do
    Logger.warning("github_budget_broker_timeout")
    {:error, :github_budget_broker_timeout}
  end

  @spec python_executable(keyword()) :: String.t() | nil
  def python_executable(opts), do: Keyword.get(opts, :python, System.find_executable("python3"))
end
