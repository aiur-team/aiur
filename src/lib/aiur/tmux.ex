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

  @doc """
  Show `text` in this pane's top border, or clear it when `text` is `nil`.

  Goes through a silent exec that never logs the value: the only caller
  surfaces the Remote Control session URL, a capability token that must
  never reach `log/`. The generic `command/3` path logs every exec at
  debug (and logs args on error), so it can't carry this value.
  """
  @spec set_pane_border(GenServer.server(), String.t(), String.t() | nil) ::
          :ok | {:error, term()}
  def set_pane_border(server \\ __MODULE__, pane_id, text)
      when is_binary(pane_id) and (is_binary(text) or is_nil(text)) do
    GenServer.call(server, {:set_pane_border, pane_id, text})
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
  Set `pane_id`'s tmux pane title (tmux's `select-pane -T`), which the
  configured `pane-border-format` renders in the pane's top border.

  Goes through the args-based exec so a title containing spaces or shell
  metacharacters is passed verbatim as a single argv element — `command/3`'s
  space-splitting would mangle it. `select-pane -T` sets the title without
  shifting the active pane, so a background pane's title can be updated
  without yanking focus.
  """
  @spec set_pane_title(GenServer.server(), String.t(), String.t()) :: :ok | {:error, term()}
  def set_pane_title(server \\ __MODULE__, pane_id, title)
      when is_binary(pane_id) and is_binary(title) do
    GenServer.call(server, {:set_pane_title, pane_id, title})
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

  @doc """
  Inject `text` into `pane_id` as a single paste via a tmux paste buffer
  (`load-buffer` from a temp file, then `paste-buffer`). Unlike
  `send_keys_literal/3`, this is not bounded by tmux's ~16KB command-length
  limit, so it can deliver large multi-line prompts in one shot. An
  application with bracketed-paste enabled (the interactive `claude` REPL
  does) receives it as a single paste rather than a keystroke-by-keystroke
  burst.
  """
  @spec paste_text(GenServer.server(), String.t(), String.t()) :: :ok | {:error, term()}
  def paste_text(server \\ __MODULE__, pane_id, text)
      when is_binary(pane_id) and is_binary(text) do
    GenServer.call(server, {:paste_text, pane_id, text})
  catch
    :exit, {:noproc, _} -> {:error, :no_tmux}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc """
  Send a single `Enter` keypress to `pane_id` (tmux's `send-keys Enter`,
  the named key — not literal text). Submits a line previously staged
  with `send_keys_literal/3`.
  """
  @spec send_enter(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def send_enter(server \\ __MODULE__, pane_id) when is_binary(pane_id) do
    GenServer.call(server, {:send_enter, pane_id})
  catch
    :exit, {:noproc, _} -> {:error, :no_tmux}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc """
  Clear the pane's current input line (tmux's `send-keys C-u`). Used to
  discard any partially-landed keystrokes before re-typing a prompt, so a
  retry can't concatenate onto a stale buffer.
  """
  @spec clear_input(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def clear_input(server \\ __MODULE__, pane_id) when is_binary(pane_id) do
    GenServer.call(server, {:clear_input, pane_id})
  catch
    :exit, {:noproc, _} -> {:error, :no_tmux}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc """
  Send a single `Ctrl+C` (tmux's `send-keys C-c`) to `pane_id`. Interrupts
  the foreground program; for the interactive `claude` REPL this stops the
  current turn at its next safe point so a queued message is consumed.
  """
  @spec send_interrupt(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def send_interrupt(server \\ __MODULE__, pane_id) when is_binary(pane_id) do
    GenServer.call(server, {:send_interrupt, pane_id})
  catch
    :exit, {:noproc, _} -> {:error, :no_tmux}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc """
  Send a single `Escape` keypress (tmux's `send-keys Escape`) to `pane_id`.
  Dismisses an in-REPL dialog (e.g. the `/rc` Remote Control panel) without
  touching the input line.
  """
  @spec send_escape(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def send_escape(server \\ __MODULE__, pane_id) when is_binary(pane_id) do
    GenServer.call(server, {:send_escape, pane_id})
  catch
    :exit, {:noproc, _} -> {:error, :no_tmux}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc """
  Capture the visible contents of `pane_id` as a list of lines
  (tmux's `capture-pane -p`). Used for coarse lifecycle signals
  (REPL readiness / idle prompt) where the transcript has no marker.
  """
  @spec capture_pane(GenServer.server(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def capture_pane(server \\ __MODULE__, pane_id) when is_binary(pane_id) do
    GenServer.call(server, {:capture_pane, pane_id}, 5_000)
  catch
    :exit, {:noproc, _} -> {:error, :no_tmux}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc """
  Kill `pane_id` (tmux's `kill-pane`). Returns `:ok` even when the pane
  is already gone, so teardown is idempotent.
  """
  @spec kill_pane(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def kill_pane(server \\ __MODULE__, pane_id) when is_binary(pane_id) do
    GenServer.call(server, {:kill_pane, pane_id}, 5_000)
  catch
    :exit, {:noproc, _} -> {:error, :no_tmux}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc """
  Return the OS pid of the top process running in `pane_id`
  (tmux's `\#{pane_pid}`). Used to graceful-kill the REPL's `claude`
  process on teardown.
  """
  @spec pane_pid(GenServer.server(), String.t()) :: {:ok, integer()} | {:error, term()}
  def pane_pid(server \\ __MODULE__, pane_id) when is_binary(pane_id) do
    GenServer.call(server, {:pane_pid, pane_id}, 5_000)
  catch
    :exit, {:noproc, _} -> {:error, :no_tmux}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc """
  List every window on the server as `{window_name, active_pane_id}` tuples
  (tmux's `list-windows -a`). Used by the REPL pane reaper/sweep to find
  `aiur-repl-*` windows across all sessions.
  """
  @spec list_windows(GenServer.server()) :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def list_windows(server \\ __MODULE__) do
    GenServer.call(server, :list_windows, 5_000)
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

  alias Aiur.Tmux.{Exec, Input, Layout, Query, Style}

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
    {:reply, Exec.run_command(state, cmd), state}
  end

  def handle_call({:set_pane_border, pane_id, text}, _from, state) do
    {:reply, Style.set_pane_border(state, pane_id, text), state}
  end

  def handle_call({:split_pane, target_pane, direction, percent, command_to_run, silent?}, _from, state) do
    {:reply, Layout.split_pane(state, target_pane, direction, percent, command_to_run, silent?), state}
  end

  def handle_call(:resolve_self_pane, _from, state) do
    {:reply, Query.resolve_self_pane(state), state}
  end

  def handle_call({:select_layout, window_target, layout_string}, _from, state) do
    {:reply, Layout.select_layout(state, window_target, layout_string), state}
  end

  def handle_call({:window_size, pane_id}, _from, state) do
    {:reply, Query.window_size(state, pane_id), state}
  end

  def handle_call({:window_for, pane_id}, _from, state) do
    {:reply, Query.window_for(state, pane_id), state}
  end

  def handle_call(:list_windows, _from, state) do
    {:reply, Query.list_windows(state), state}
  end

  def handle_call({:list_panes, window_target}, _from, state) do
    {:reply, Query.list_panes(state, window_target), state}
  end

  def handle_call({:respawn_pane, pane_id, command_to_run}, _from, state) do
    {:reply, Layout.respawn_pane(state, pane_id, command_to_run), state}
  end

  def handle_call({:send_keys_literal, pane_id, text}, _from, state) do
    {:reply, Input.send_keys_literal(state, pane_id, text), state}
  end

  def handle_call({:paste_text, pane_id, text}, _from, state) do
    {:reply, Input.paste_text(state, pane_id, text), state}
  end

  def handle_call({:send_enter, pane_id}, _from, state) do
    {:reply, Input.send_enter(state, pane_id), state}
  end

  def handle_call({:clear_input, pane_id}, _from, state) do
    {:reply, Input.clear_input(state, pane_id), state}
  end

  def handle_call({:send_interrupt, pane_id}, _from, state) do
    {:reply, Input.send_interrupt(state, pane_id), state}
  end

  def handle_call({:send_escape, pane_id}, _from, state) do
    {:reply, Input.send_escape(state, pane_id), state}
  end

  def handle_call({:capture_pane, pane_id}, _from, state) do
    {:reply, Query.capture_pane(state, pane_id), state}
  end

  def handle_call({:pane_pid, pane_id}, _from, state) do
    {:reply, Query.pane_pid(state, pane_id), state}
  end

  def handle_call({:kill_pane, pane_id}, _from, state) do
    {:reply, Layout.kill_pane(state, pane_id), state}
  end

  def handle_call({:new_hidden_window, window_name, command_to_run}, _from, state) do
    {:reply, Layout.new_hidden_window(state, window_name, command_to_run), state}
  end

  def handle_call({:join_pane, source_pane, target_window}, _from, state) do
    {:reply, Layout.join_pane(state, source_pane, target_window), state}
  end

  def handle_call({:move_pane_hidden, source_pane, target_window}, _from, state) do
    {:reply, Layout.move_pane_hidden(state, source_pane, target_window), state}
  end

  def handle_call({:move_pane_visible, source_pane, target_window}, _from, state) do
    {:reply, Layout.move_pane_visible(state, source_pane, target_window), state}
  end

  def handle_call({:set_pane_title, pane_id, title}, _from, state) do
    {:reply, Style.set_pane_title(state, pane_id, title), state}
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

  defp default_session do
    case System.get_env(@default_session_env) do
      value when is_binary(value) and value != "" -> value
      _ -> @default_session_fallback
    end
  end
end
