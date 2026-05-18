defmodule Aiur.Tmux do
  @moduledoc """
  tmux integration via shell-out commands.

  Phase 1 keeps things simple: each command shells out via `System.cmd/3` to
  `tmux <args>`. Control-mode (`tmux -CC attach`) was tried first but requires
  a TTY for the attached client, which a BEAM Port does not provide. The
  shell-out path works without a TTY and is fast enough for human-paced pane
  operations.

  Targets the session named by `AIUR_TMUX_SESSION` (set by the `aiur`
  wrapper). Tests inject a `:transport` of `{:mock, pid}` and observe outbound
  command strings as `{:tmux_mock_out, command}` messages while
  injecting responses (currently unused) via `{:tmux_mock_data, chunk}`.
  """

  use GenServer
  require Logger

  alias Aiur.AgentEvents

  @default_session_env "AIUR_TMUX_SESSION"
  @default_session_fallback "aiur"

  @type command_response :: {:ok, [String.t()]} | {:error, term()}

  # Public API ----------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec command(GenServer.server(), String.t(), timeout()) :: command_response()
  def command(server \\ __MODULE__, command, timeout \\ 5_000) when is_binary(command) do
    GenServer.call(server, {:command, command}, timeout)
  catch
    :exit, {:noproc, _} -> {:error, :no_tmux}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @spec subscribe_events(GenServer.server()) :: :ok | {:error, term()}
  def subscribe_events(server \\ __MODULE__) do
    GenServer.call(server, {:subscribe, self()})
  catch
    :exit, {:noproc, _} -> {:error, :no_tmux}
  end

  @spec spawn_pane_for(GenServer.server(), AgentEvents.agent_identifier(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def spawn_pane_for(server \\ __MODULE__, identifier, command_to_run)
      when is_binary(identifier) and is_binary(command_to_run) do
    GenServer.call(server, {:spawn_pane, identifier, command_to_run}, 10_000)
  catch
    :exit, {:noproc, _} -> {:error, :no_tmux}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc """
  Split an existing pane and start `command_to_run` in the new pane.
  Direction is `:horizontal` (new pane to the right) or `:vertical`
  (new pane below); `percent` sets the new pane's size as a percentage
  of the target pane.
  """
  @spec split_pane(GenServer.server(), String.t(), :horizontal | :vertical, pos_integer(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def split_pane(server \\ __MODULE__, target_pane_id, direction, percent, command_to_run)
      when is_binary(target_pane_id) and direction in [:horizontal, :vertical] and
             is_integer(percent) and percent > 0 and percent < 100 and is_binary(command_to_run) do
    GenServer.call(server, {:split_pane, target_pane_id, direction, percent, command_to_run}, 10_000)
  catch
    :exit, {:noproc, _} -> {:error, :no_tmux}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc """
  Kill the command running in `pane_id` and replace it with a fresh
  process running `command_to_run`. Pane id stays the same, so the
  physical position in the tmux layout doesn't change.
  """
  @spec respawn_pane(GenServer.server(), String.t(), String.t()) :: :ok | {:error, term()}
  def respawn_pane(server \\ __MODULE__, pane_id, command_to_run)
      when is_binary(pane_id) and is_binary(command_to_run) do
    GenServer.call(server, {:respawn_pane, pane_id, command_to_run}, 10_000)
  catch
    :exit, {:noproc, _} -> {:error, :no_tmux}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @spec session(GenServer.server()) :: String.t()
  def session(server \\ __MODULE__), do: GenServer.call(server, :session)

  # GenServer callbacks -------------------------------------------------------

  @impl true
  def init(opts) do
    transport = Keyword.get(opts, :transport, :shell)
    session = Keyword.get(opts, :session, default_session())

    state = %{
      transport: transport,
      session: session,
      subscribers: MapSet.new()
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:command, cmd}, _from, state) do
    {:reply, run_command(state, cmd), state}
  end

  def handle_call({:spawn_pane, identifier, command_to_run}, _from, state) do
    target = "#{state.session}:.{right}"

    args = ["split-window", "-t", target, "-h", "-P", "-F", "\#{pane_id}", command_to_run]

    case run_args(state, args) do
      {:ok, [pane_id | _]} ->
        new_id = String.trim(pane_id)
        _ = run_args(state, ["select-pane", "-t", new_id])
        {:reply, {:ok, new_id}, state}

      {:ok, []} ->
        {:reply, {:error, :no_pane_id}, state}

      {:error, _} = err ->
        Logger.warning("Tmux split-window for #{identifier} failed: #{inspect(err)}")
        {:reply, err, state}
    end
  end

  def handle_call({:split_pane, target_pane, direction, percent, command_to_run}, _from, state) do
    direction_flag = if direction == :horizontal, do: "-h", else: "-v"

    args = [
      "split-window",
      "-t",
      target_pane,
      direction_flag,
      "-p",
      Integer.to_string(percent),
      "-P",
      "-F",
      "\#{pane_id}",
      command_to_run
    ]

    case run_args(state, args) do
      {:ok, [pane_id | _]} ->
        new_id = String.trim(pane_id)
        _ = run_args(state, ["select-pane", "-t", new_id])
        {:reply, {:ok, new_id}, state}

      {:ok, []} ->
        {:reply, {:error, :no_pane_id}, state}

      {:error, _} = err ->
        Logger.warning("Tmux split-window failed for target=#{target_pane}: #{inspect(err)}")
        {:reply, err, state}
    end
  end

  def handle_call({:respawn_pane, pane_id, command_to_run}, _from, state) do
    # `-k` kills the existing command in the pane; tmux then starts the
    # new command in the same pane id, preserving the layout position.
    args = ["respawn-pane", "-k", "-t", pane_id, command_to_run]

    case run_args(state, args) do
      {:ok, _} -> {:reply, :ok, state}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  def handle_call(:session, _from, state), do: {:reply, state.session, state}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  def handle_info({:tmux_mock_data, _chunk}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  # Internals -----------------------------------------------------------------

  defp run_command(%{transport: {:mock, pid}}, cmd) do
    send(pid, {:tmux_mock_out, cmd})
    receive_mock_response()
  end

  defp run_command(%{transport: :shell} = state, cmd) do
    run_args(state, split_command(cmd))
  end

  defp run_args(%{transport: {:mock, pid}}, args) do
    send(pid, {:tmux_mock_out, Enum.join(args, " ")})
    receive_mock_response()
  end

  defp run_args(%{transport: :shell}, args) do
    full_args = prepend_socket(args)
    Logger.debug("Tmux exec: tmux #{Enum.join(full_args, " ")}")

    case System.find_executable("tmux") do
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
            trimmed = String.trim(output)

            Logger.warning("Tmux exec exit=#{status} args=#{inspect(full_args)} output=#{inspect(trimmed)}")

            {:error, trimmed}
        end
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

  defp receive_mock_response do
    receive do
      {:tmux_mock_data, "%begin " <> _ = chunk} -> parse_mock_response(chunk)
    after
      1_000 -> {:error, :no_mock_response}
    end
  end

  defp parse_mock_response(chunk) do
    lines = String.split(chunk, "\n", trim: true)

    body =
      Enum.reduce(lines, [], fn line, acc ->
        cond do
          String.starts_with?(line, "%begin") -> acc
          String.starts_with?(line, "%end") -> acc
          String.starts_with?(line, "%error") -> acc
          true -> [line | acc]
        end
      end)
      |> Enum.reverse()

    if Enum.any?(lines, &String.starts_with?(&1, "%error")) do
      {:error, body}
    else
      {:ok, body}
    end
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

  defp default_session do
    case System.get_env(@default_session_env) do
      value when is_binary(value) and value != "" -> value
      _ -> @default_session_fallback
    end
  end
end
