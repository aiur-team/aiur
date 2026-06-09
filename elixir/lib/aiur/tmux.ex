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

  @doc """
  Split an existing pane and start `command_to_run` in the new pane.
  Direction is `:horizontal` (new pane to the right) or `:vertical`
  (new pane below); `percent` sets the new pane's size as a percentage
  of the target pane.

  Options:
  - `:silent` (default `false`) — when `true`, do NOT call `select-pane`
    after the split. `select-pane` switches tmux's active window to the
    one containing the new pane, which is harmful when splitting into
    a hidden window because it drags the attached client there.
  """
  @spec split_pane(
          GenServer.server(),
          String.t(),
          :horizontal | :vertical,
          pos_integer(),
          String.t(),
          keyword()
        ) ::
          {:ok, String.t()} | {:error, term()}
  def split_pane(server \\ __MODULE__, target_pane_id, direction, percent, command_to_run, opts \\ [])
      when is_binary(target_pane_id) and direction in [:horizontal, :vertical] and
             is_integer(percent) and percent > 0 and percent < 100 and is_binary(command_to_run) and
             is_list(opts) do
    silent? = Keyword.get(opts, :silent, false)

    GenServer.call(
      server,
      {:split_pane, target_pane_id, direction, percent, command_to_run, silent?},
      10_000
    )
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

  @doc """
  Create a new tmux window detached from the current view and run
  `command_to_run` inside it. Returns the pane id of the new pane.

  Used by `Aiur.Opencode.HiddenWindow` to create the persistent hidden
  warm window at boot; `move_pane_visible/2` later promotes background
  panes from this window into the visible agents window.
  """
  @spec new_hidden_window(GenServer.server(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def new_hidden_window(server \\ __MODULE__, window_name, command_to_run)
      when is_binary(window_name) and is_binary(command_to_run) do
    GenServer.call(server, {:new_hidden_window, window_name, command_to_run}, 10_000)
  catch
    :exit, {:noproc, _} -> {:error, :no_tmux}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc """
  Move `source_pane` into `target_window`. Preserves the running
  process and the pane id — verified against tmux 3.5a on aiur's
  isolated socket.
  """
  @spec join_pane(GenServer.server(), String.t(), String.t()) :: :ok | {:error, term()}
  def join_pane(server \\ __MODULE__, source_pane, target_window)
      when is_binary(source_pane) and is_binary(target_window) do
    GenServer.call(server, {:join_pane, source_pane, target_window}, 10_000)
  catch
    :exit, {:noproc, _} -> {:error, :no_tmux}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc """
  Move `source_pane` into a hidden `target_window` without stealing
  focus. tmux's `move-pane -d` flag detaches the move from the active
  selection so the user keeps looking at the visible window. Preserves
  PID and pane id — verified equivalent to `join-pane` in tmux 3.5a.

  Used by `Aiur.PaneManager` close path and by `Aiur.Opencode.Slot`
  workers when their attached pane goes hidden.
  """
  @spec move_pane_hidden(GenServer.server(), String.t(), String.t()) :: :ok | {:error, term()}
  def move_pane_hidden(server \\ __MODULE__, source_pane, target_window)
      when is_binary(source_pane) and is_binary(target_window) do
    GenServer.call(server, {:move_pane_hidden, source_pane, target_window}, 10_000)
  catch
    :exit, {:noproc, _} -> {:error, :no_tmux}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc """
  Move `source_pane` into the visible `target_window`, splitting
  horizontally next to existing panes. Caller is responsible for any
  follow-up layout reflow.
  """
  @spec move_pane_visible(GenServer.server(), String.t(), String.t()) :: :ok | {:error, term()}
  def move_pane_visible(server \\ __MODULE__, source_pane, target_window)
      when is_binary(source_pane) and is_binary(target_window) do
    GenServer.call(server, {:move_pane_visible, source_pane, target_window}, 10_000)
  catch
    :exit, {:noproc, _} -> {:error, :no_tmux}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc """
  Send `text` to `pane_id` as a single literal keystroke buffer (tmux's
  `send-keys -l`). Bypasses the string-split parsing in `command/3` which
  would mangle whitespace and quote characters.
  """
  @spec send_keys_literal(GenServer.server(), String.t(), String.t()) :: :ok | {:error, term()}
  def send_keys_literal(server \\ __MODULE__, pane_id, text)
      when is_binary(pane_id) and is_binary(text) do
    GenServer.call(server, {:send_keys_literal, pane_id, text})
  catch
    :exit, {:noproc, _} -> {:error, :no_tmux}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @spec session(GenServer.server()) :: String.t()
  def session(server \\ __MODULE__), do: GenServer.call(server, :session)

  @doc """
  Resolve the pane id of the BEAM's own tmux pane via `tmux
  display-message`, validating that `$TMUX_PANE` (set by tmux when it
  launched the pane's shell) points to a live pane on the configured
  server. Returns `{:ok, pane_id}` or `{:error, reason}`.

  Used by `Aiur.PaneManager` at startup to anchor the conversation
  layout. Refusing to start when this fails is preferable to silently
  losing the anchor and watching every conversation pane fall back to
  the legacy "split rightmost" path — that mode was the root cause of
  the regression issue #34 tracks.
  """
  @spec resolve_self_pane(GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def resolve_self_pane(server \\ __MODULE__) do
    GenServer.call(server, :resolve_self_pane, 5_000)
  catch
    :exit, {:noproc, _} -> {:error, :no_tmux}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc """
  Apply a tmux layout string to the named window. The string is the
  same format as `tmux list-windows -F '\#{window_layout}'` returns,
  including the 4-char hex checksum prefix.
  """
  @spec select_layout(GenServer.server(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def select_layout(server \\ __MODULE__, window_target, layout_string)
      when is_binary(window_target) and is_binary(layout_string) do
    GenServer.call(server, {:select_layout, window_target, layout_string}, 5_000)
  catch
    :exit, {:noproc, _} -> {:error, :no_tmux}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc """
  Return the pixel-cell dimensions of the window containing `pane_id`,
  as `{:ok, {width, height}}`. Used by the layout-string builder.
  """
  @spec window_size(GenServer.server(), String.t()) ::
          {:ok, {pos_integer(), pos_integer()}} | {:error, term()}
  def window_size(server \\ __MODULE__, pane_id) when is_binary(pane_id) do
    GenServer.call(server, {:window_size, pane_id}, 5_000)
  catch
    :exit, {:noproc, _} -> {:error, :no_tmux}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc """
  Return the tmux window target (`session:window-index`) containing
  `pane_id`. The window-id format is stable across pane rearrangements,
  so the result is safe to cache.
  """
  @spec window_for(GenServer.server(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def window_for(server \\ __MODULE__, pane_id) when is_binary(pane_id) do
    GenServer.call(server, {:window_for, pane_id}, 5_000)
  catch
    :exit, {:noproc, _} -> {:error, :no_tmux}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc """
  Return pane ids currently visible in `window_target`.

  PaneManager uses this as the authoritative source before opening a
  chat pane so stale state from externally closed panes does not distort
  the next layout pass.
  """
  @spec list_panes(GenServer.server(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_panes(server \\ __MODULE__, window_target) when is_binary(window_target) do
    GenServer.call(server, {:list_panes, window_target}, 5_000)
  catch
    :exit, {:noproc, _} -> {:error, :no_tmux}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

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

  def handle_call({:split_pane, target_pane, direction, percent, command_to_run, silent?}, _from, state) do
    direction_flag = if direction == :horizontal, do: "-h", else: "-v"

    # `-l N%` is the modern way to size the new pane; tmux 3.5+ tightened
    # parsing of the deprecated `-p N` form and returns "size missing" on
    # detached sessions when the percentage flag isn't paired with a `-l`.
    # `-d` keeps the active pane selection where it is, so a split into
    # a hidden window does not drag the attached client there.
    base_args =
      if silent? do
        ["split-window", "-d", "-t", target_pane, direction_flag, "-l", "#{percent}%"]
      else
        ["split-window", "-t", target_pane, direction_flag, "-l", "#{percent}%"]
      end

    args = base_args ++ ["-P", "-F", "\#{pane_id}", command_to_run]

    case run_args(state, args) do
      {:ok, [pane_id | _]} ->
        new_id = String.trim(pane_id)
        unless silent?, do: run_args(state, ["select-pane", "-t", new_id])
        {:reply, {:ok, new_id}, state}

      {:ok, []} ->
        {:reply, {:error, :no_pane_id}, state}

      {:error, _} = err ->
        Logger.warning("Tmux split-window failed for target=#{target_pane}: #{inspect(err)}")
        {:reply, err, state}
    end
  end

  def handle_call(:resolve_self_pane, _from, state) do
    env_pane = System.get_env("TMUX_PANE")

    reply =
      if is_binary(env_pane) and env_pane != "" do
        case run_args(state, ["display-message", "-p", "-t", env_pane, "\#{pane_id}"]) do
          {:ok, [id | _]} ->
            {:ok, String.trim(id)}

          {:ok, []} ->
            {:error, :no_pane_id}

          {:error, _} = err ->
            err
        end
      else
        {:error, :no_tmux_pane_env}
      end

    {:reply, reply, state}
  end

  def handle_call({:select_layout, window_target, layout_string}, _from, state) do
    args = ["select-layout", "-t", window_target, layout_string]

    case run_args(state, args) do
      {:ok, _} ->
        {:reply, :ok, state}

      {:error, _} = err ->
        Logger.warning("Tmux select-layout failed for window=#{window_target}: #{inspect(err)}")
        {:reply, err, state}
    end
  end

  def handle_call({:window_size, pane_id}, _from, state) do
    case run_args(state, [
           "display-message",
           "-p",
           "-t",
           pane_id,
           "\#{window_width}x\#{window_height}"
         ]) do
      {:ok, [dims | _]} ->
        case parse_dims(dims) do
          {:ok, _} = ok -> {:reply, ok, state}
          err -> {:reply, err, state}
        end

      {:ok, []} ->
        {:reply, {:error, :no_dims}, state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:window_for, pane_id}, _from, state) do
    case run_args(state, [
           "display-message",
           "-p",
           "-t",
           pane_id,
           "\#{session_name}:\#{window_index}"
         ]) do
      {:ok, [target | _]} -> {:reply, {:ok, String.trim(target)}, state}
      {:ok, []} -> {:reply, {:error, :no_window}, state}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:list_panes, window_target}, _from, state) do
    case run_args(state, ["list-panes", "-t", window_target, "-F", "\#{pane_id}"]) do
      {:ok, pane_ids} ->
        {:reply, {:ok, Enum.map(pane_ids, &String.trim/1)}, state}

      {:error, _} = err ->
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

  def handle_call({:send_keys_literal, pane_id, text}, _from, state) do
    case run_args(state, ["send-keys", "-t", pane_id, "-l", text]) do
      {:ok, _} -> {:reply, :ok, state}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:new_hidden_window, window_name, command_to_run}, _from, state) do
    # `-d` keeps the new window in the background; `-P -F #{pane_id}` makes
    # tmux print the pane id so we can target it later for `join-pane`.
    args = ["new-window", "-d", "-n", window_name, "-P", "-F", "\#{pane_id}", command_to_run]

    case run_args(state, args) do
      {:ok, [pane_id | _]} -> {:reply, {:ok, String.trim(pane_id)}, state}
      {:ok, []} -> {:reply, {:error, :no_pane_id}, state}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:join_pane, source_pane, target_window}, _from, state) do
    # `-h` makes the joined pane a horizontal split next to the existing
    # panes in the target window; layout reflow happens on the caller side.
    case run_args(state, ["join-pane", "-s", source_pane, "-t", target_window, "-h"]) do
      {:ok, _} -> {:reply, :ok, state}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:move_pane_hidden, source_pane, target_window}, _from, state) do
    # `-d` detaches the move from the active selection (no focus shift).
    # `-h` keeps tmux happy when the destination window has existing panes.
    case run_args(state, ["move-pane", "-d", "-s", source_pane, "-t", target_window, "-h"]) do
      {:ok, _} -> {:reply, :ok, state}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:move_pane_visible, source_pane, target_window}, _from, state) do
    case run_args(state, ["move-pane", "-s", source_pane, "-t", target_window, "-h"]) do
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

            # "no server running on …" repeats every screen-grab tick
            # (2s) once the user kills the tmux server but leaves the
            # operator BEAM running. Demote those to debug so the log
            # isn't flooded — pane_manager still treats `{:error, _}`
            # the same way, so behavior doesn't change.
            log_tmux_exit(status, full_args, trimmed)

            {:error, trimmed}
        end
    end
  end

  defp log_tmux_exit(status, full_args, trimmed) do
    if String.contains?(trimmed, "no server running") do
      Logger.debug("Tmux exec exit=#{status} args=#{inspect(full_args)} output=#{inspect(trimmed)}")
    else
      Logger.warning("Tmux exec exit=#{status} args=#{inspect(full_args)} output=#{inspect(trimmed)}")
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

  defp parse_dims(text) do
    case String.split(String.trim(text), "x", parts: 2) do
      [w_str, h_str] ->
        with {w, ""} <- Integer.parse(w_str),
             {h, ""} <- Integer.parse(h_str),
             true <- w > 0 and h > 0 do
          {:ok, {w, h}}
        else
          _ -> {:error, {:bad_dims, text}}
        end

      _ ->
        {:error, {:bad_dims, text}}
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
