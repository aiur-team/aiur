defmodule Aiur.Tmux.Layout do
  @moduledoc """
  Pane/window creation, movement, destruction, and layout. Each function takes
  the exec context map as its first argument and returns a plain result tuple.
  """

  require Logger
  alias Aiur.Tmux.Exec

  @spec split_pane(
          map(),
          String.t(),
          :horizontal | :vertical,
          pos_integer(),
          String.t(),
          boolean()
        ) :: {:ok, String.t()} | {:error, term()}
  def split_pane(state, target_pane, direction, percent, command_to_run, silent?) do
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

    case Exec.run_args(state, args) do
      {:ok, [pane_id | _]} ->
        new_id = String.trim(pane_id)
        unless silent?, do: Exec.run_args(state, ["select-pane", "-t", new_id])
        {:ok, new_id}

      {:ok, []} ->
        {:error, :no_pane_id}

      {:error, _} = err ->
        Logger.warning("Tmux split-window failed for target=#{target_pane}: #{inspect(err)}")
        err
    end
  end

  @spec respawn_pane(map(), String.t(), String.t()) :: :ok | {:error, term()}
  def respawn_pane(state, pane_id, command_to_run) do
    # `-k` kills the existing command in the pane; tmux then starts the
    # new command in the same pane id, preserving the layout position.
    args = ["respawn-pane", "-k", "-t", pane_id, command_to_run]

    case Exec.run_args(state, args) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @spec new_hidden_window(map(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def new_hidden_window(state, window_name, command_to_run) do
    # `-d` keeps the new window in the background; `-P -F #{pane_id}` makes
    # tmux print the pane id so we can target it later for `join-pane`.
    args = ["new-window", "-d", "-n", window_name, "-P", "-F", "\#{pane_id}", command_to_run]

    case Exec.run_args(state, args) do
      {:ok, [pane_id | _]} ->
        {:ok, String.trim(pane_id)}

      {:ok, []} ->
        {:error, :no_pane_id}

      # `new-window` needs a running server. When aiur runs standalone (TUI
      # in the terminal or a `--bg` nohup BEAM, not inside an aiurdev tmux
      # session), the socket has no server yet — so the first REPL spawn must
      # create the session, which starts the server, rather than failing into
      # the headless fallback. Later spawns reuse the server via `new-window`.
      {:error, reason} = err ->
        if no_server?(reason) do
          bootstrap_window(state, window_name, command_to_run)
        else
          err
        end
    end
  end

  @spec join_pane(map(), String.t(), String.t()) :: :ok | {:error, term()}
  def join_pane(state, source_pane, target_window) do
    # `-h` makes the joined pane a horizontal split next to the existing
    # panes in the target window; layout reflow happens on the caller side.
    case Exec.run_args(state, ["join-pane", "-s", source_pane, "-t", target_window, "-h"]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @spec move_pane_hidden(map(), String.t(), String.t()) :: :ok | {:error, term()}
  def move_pane_hidden(state, source_pane, target_window) do
    # `-d` detaches the move from the active selection (no focus shift).
    # `-h` keeps tmux happy when the destination window has existing panes.
    case Exec.run_args(state, ["move-pane", "-d", "-s", source_pane, "-t", target_window, "-h"]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @spec move_pane_visible(map(), String.t(), String.t()) :: :ok | {:error, term()}
  def move_pane_visible(state, source_pane, target_window) do
    case Exec.run_args(state, ["move-pane", "-s", source_pane, "-t", target_window, "-h"]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @spec kill_pane(map(), String.t()) :: :ok | {:error, term()}
  def kill_pane(state, pane_id) do
    case Exec.run_args(state, ["kill-pane", "-t", pane_id]) do
      {:ok, _} ->
        :ok

      # A pane that's already gone ("can't find pane") is success for
      # idempotent teardown; other failures surface.
      {:error, reason} = err ->
        if reason |> List.wrap() |> Enum.any?(&(is_binary(&1) and String.contains?(&1, "can't find pane"))) do
          :ok
        else
          err
        end
    end
  end

  @spec select_layout(map(), String.t(), String.t()) :: :ok | {:error, term()}
  def select_layout(state, window_target, layout_string) do
    args = ["select-layout", "-t", window_target, layout_string]

    case Exec.run_args(state, args) do
      {:ok, _} ->
        :ok

      {:error, _} = err ->
        Logger.warning("Tmux select-layout failed for window=#{window_target}: #{inspect(err)}")
        err
    end
  end

  defp no_server?(reason) do
    reason
    |> List.wrap()
    |> Enum.any?(&(is_binary(&1) and String.contains?(&1, "no server running")))
  end

  # Create the holder session detached, running the REPL command as its first
  # window — `new-session` starts the server when none exists, so the pane is
  # spawned in one shot and `-P -F #{pane_id}` prints its id.
  defp bootstrap_window(state, window_name, command_to_run) do
    args = [
      "new-session",
      "-d",
      "-s",
      state.session,
      "-n",
      window_name,
      "-P",
      "-F",
      "\#{pane_id}",
      command_to_run
    ]

    case Exec.run_args(state, args) do
      {:ok, [pane_id | _]} -> {:ok, String.trim(pane_id)}
      {:ok, []} -> {:error, :no_pane_id}
      {:error, _} = err -> err
    end
  end
end
