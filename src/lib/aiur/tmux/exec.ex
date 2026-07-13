defmodule Aiur.Tmux.Exec do
  @moduledoc """
  Transport layer for tmux shell-out commands. Single source of truth for how
  a tmux command is executed: socket-flag injection, binary resolution with
  `:persistent_term` cache, exec-logging policy, exit-status handling, and the
  command-string → argv splitter.
  """

  require Logger
  alias Aiur.Tmux.MockTransport

  @spec run_command(map(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def run_command(%{transport: {:mock, pid}}, cmd) do
    MockTransport.request(pid, cmd)
  end

  def run_command(%{transport: :shell} = state, cmd) do
    run_args(state, split_command(cmd))
  end

  @spec run_args(map(), [String.t()]) :: {:ok, [String.t()]} | {:error, term()}
  def run_args(%{transport: {:mock, pid}}, args) do
    MockTransport.request(pid, Enum.join(args, " "))
  end

  def run_args(%{transport: :shell}, args) do
    full_args = prepend_socket(args)
    Logger.debug("Tmux exec: tmux #{Enum.join(full_args, " ")}")

    case tmux_executable() do
      nil ->
        Logger.warning("Tmux exec failed: tmux not in $PATH")
        {:error, :no_tmux_executable}

      tmux ->
        case System.cmd(tmux, full_args, stderr_to_stdout: true) do
          {output, 0} ->
            result = output |> String.trim_trailing("\n") |> String.split("\n", trim: true)
            Logger.debug("Tmux exec ok: #{inspect(result)}")
            {:ok, result}

          {output, status} ->
            handle_tmux_exit(String.trim(output), status, full_args)
        end
    end
  end

  # Like `run_args/2` but never logs the args — they may carry the RC
  # session URL (a capability token). The mock transport already routes to
  # the test pid rather than Logger, so only the shell path needs a
  # value-free variant; on error it logs the subcommand and status only.
  @spec run_args_silent(map(), [String.t()]) :: {:ok, [String.t()]} | {:error, term()}
  def run_args_silent(%{transport: {:mock, _}} = state, args), do: run_args(state, args)

  def run_args_silent(%{transport: :shell}, args) do
    full_args = prepend_socket(args)

    case tmux_executable() do
      nil ->
        Logger.warning("Tmux exec failed: tmux not in $PATH")
        {:error, :no_tmux_executable}

      tmux ->
        case System.cmd(tmux, full_args, stderr_to_stdout: true) do
          {output, 0} ->
            {:ok, output |> String.trim_trailing("\n") |> String.split("\n", trim: true)}

          {output, status} ->
            Logger.warning("Tmux silent exec exit=#{status} subcommand=#{redact_subcommand(args)}")
            {:error, String.trim(output)}
        end
    end
  end

  # Resolve the tmux binary once: a $PATH walk per command is pure overhead on
  # the hottest fork path (the per-slot liveness poll). `:persistent_term` is
  # built for read-mostly global constants — the one-time `put` cost is paid on
  # the first exec, every later read is free.
  defp tmux_executable do
    case :persistent_term.get({__MODULE__, :tmux_bin}, nil) do
      nil ->
        bin = System.find_executable("tmux")
        if bin, do: :persistent_term.put({__MODULE__, :tmux_bin}, bin)
        bin

      bin ->
        bin
    end
  end

  # Read AIUR_TMUX_SOCKET each invocation so the Tmux GenServer (started
  # before the wrapper exports the var, in some test paths) still picks it up.
  defp prepend_socket(args) do
    case System.get_env("AIUR_TMUX_SOCKET") do
      socket when is_binary(socket) and socket != "" -> ["-L", socket | args]
      _ -> args
    end
  end

  defp handle_tmux_exit(trimmed, status, full_args) do
    # "no server running on …" repeats every screen-grab tick
    # (2s) once the user kills the tmux server but leaves the
    # Executor BEAM running. Demote those to debug so the log
    # isn't flooded — pane_manager still treats `{:error, _}`
    # the same way, so behavior doesn't change.
    if String.contains?(trimmed, "no server running") do
      Logger.debug("Tmux exec exit=#{status} args=#{inspect(full_args)} output=#{inspect(trimmed)}")
    else
      Logger.warning("Tmux exec exit=#{status} args=#{inspect(full_args)} output=#{inspect(trimmed)}")
    end

    {:error, trimmed}
  end

  # First two tokens identify the operation (e.g. "set-option -p") without
  # exposing any value argument that might contain a secret.
  defp redact_subcommand(args) do
    args |> Enum.take(2) |> Enum.join(" ")
  end

  defp split_command(cmd) do
    {tokens, _} =
      cmd
      |> String.split(~r/\s+/, trim: true)
      |> Enum.reduce({[], nil}, &split_command_step/2)

    Enum.reverse(tokens)
  end

  defp split_command_step(token, {acc, nil}) do
    if String.starts_with?(token, "\"") do
      start_quoted(token, acc)
    else
      {[token | acc], nil}
    end
  end

  defp split_command_step(token, {acc, quoted}), do: continue_quoted(token, quoted, acc)

  defp start_quoted(token, acc) do
    inner = String.trim_leading(token, "\"")

    if String.ends_with?(inner, "\"") do
      {[String.trim_trailing(inner, "\"") | acc], nil}
    else
      {acc, inner}
    end
  end

  defp continue_quoted(token, quoted, acc) do
    joined = quoted <> " " <> token

    if String.ends_with?(joined, "\"") do
      {[String.trim_trailing(joined, "\"") | acc], nil}
    else
      {acc, joined}
    end
  end
end
