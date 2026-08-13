defmodule Aiur.Opencode.Slot.AttachPane do
  @moduledoc """
  tmux attach-pane surface for a slot: spawn, respawn, probe, and forensics.

  All functions are plain in-process calls — no processes are started here
  except the already-existing tmux pane and ProcessReaper interactions.
  """

  require Logger

  alias Aiur.Opencode.{HiddenWindow, Protocol, SlotSupervisor}
  alias Aiur.Tmux

  @hidden_split_percent 50

  @doc """
  The slot owns its opencode-attach pane. On teardown the pane must be
  killed, or the attach client and its inner tmux session outlive an Aiur
  quit and leak the whole UI subtree. Returns nil when there is no pane.
  """
  @spec terminate_pane_command(map()) :: String.t() | nil
  def terminate_pane_command(%{pane_id: pane_id}) when is_binary(pane_id),
    do: "kill-pane -t #{pane_id}"

  def terminate_pane_command(_state), do: nil

  @doc "Spawn the initial no-session attach pane into `keep_alive_pane`'s window."
  @spec spawn(integer(), String.t(), String.t()) :: {:ok, String.t()} | term()
  def spawn(_slot_index, base_url, keep_alive_pane) do
    attach_cmd = Protocol.attach_command(base_url)

    resize_hidden_window_for_live_slots()

    with {:ok, pane_id} <-
           Tmux.split_pane(
             Tmux,
             keep_alive_pane,
             :horizontal,
             @hidden_split_percent,
             attach_cmd,
             silent: true
           ) do
      Aiur.ProcessReaper.register(:agent, {:pane, pane_id})
      {:ok, pane_id}
    end
  end

  defp resize_hidden_window_for_live_slots do
    slot_count = max(SlotSupervisor.slot_count(), 1)

    with {:ok, [dims | _]} <- Tmux.command(Tmux, "display-message -p -t aiur-orangekid-default:0 \"\#{window_width} \#{window_height}\""),
         [width, height] <- String.split(String.trim(dims), " ", trim: true),
         {term_w, ""} <- Integer.parse(width),
         {term_h, ""} <- Integer.parse(height) do
      pane_width = max(div(term_w, 2), 40)
      _ = Tmux.command(Tmux, "resize-window -t aiur-orangekid-default:aiur-hidden -x #{pane_width * slot_count} -y #{term_h}")
      _ = Tmux.command(Tmux, "select-layout -t aiur-orangekid-default:aiur-hidden even-horizontal")
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Kill the existing attach pane and spawn a fresh one bound to `session_id`.
  `attach_cmd` must be pre-built as `Protocol.attach_command(state.base_url, session_id)`
  by the caller.
  """
  @spec respawn_with_session(map(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :respawn_failed}
  def respawn_with_session(state, session_id, attach_cmd) do
    span =
      Aiur.Perf.span_begin(:slot_respawn_attach,
        slot: state.slot_index,
        session_id: session_id
      )

    if is_binary(state.pane_id) do
      Logger.warning("opencode_slot phase=kill_for_respawn slot=#{state.slot_index} old_pane_id=#{state.pane_id} session_id=#{session_id}")

      Aiur.ProcessReaper.unregister({:pane, state.pane_id})
      _ = Tmux.command(Tmux, "kill-pane -t #{state.pane_id}")
    end

    with {:ok, keep_alive_pane} <- hidden_window_target(),
         :ok <- reflow_hidden_window(keep_alive_pane),
         {:ok, pane_id} <-
           Tmux.split_pane(
             Tmux,
             keep_alive_pane,
             :horizontal,
             @hidden_split_percent,
             attach_cmd,
             silent: true
           ) do
      Aiur.Perf.span_end(span,
        slot: state.slot_index,
        session_id: session_id,
        pane_id: pane_id
      )

      Aiur.ProcessReaper.register(:agent, {:pane, pane_id})
      maybe_start_pipe_pane(state.slot_index, pane_id)

      {:ok, pane_id}
    else
      error ->
        Logger.warning("opencode_slot phase=respawn_attach_failed slot=#{state.slot_index} session_id=#{session_id} reason=#{inspect(error)}")

        Aiur.Perf.span_end(span,
          result: :failed,
          slot: state.slot_index,
          session_id: session_id
        )

        {:error, :respawn_failed}
    end
  end

  @doc "Kill a pane, optionally unregistering it from ProcessReaper first."
  @spec kill(String.t(), keyword()) :: :ok
  def kill(pane_id, opts \\ []) do
    if Keyword.get(opts, :unregister, true) do
      Aiur.ProcessReaper.unregister({:pane, pane_id})
    end

    _ = Tmux.command(Tmux, "kill-pane -t #{pane_id}")
    :ok
  end

  @doc """
  Probe whether the pane is still alive via tmux display-message.

  tmux's `display-message -t <pane>` returns empty under transient
  load even when the pane is alive (verified against a real run
  where capture-pane on a freshly-spawned sibling was returning
  empty in a tight loop). One bad reading is not enough — require
  poll_death_threshold consecutive failures before tearing the
  slot down.
  """
  @spec probe(String.t()) :: :alive | {:missing, term()}
  def probe(pane_id) do
    result = Tmux.command(Tmux, "display-message -p -t #{pane_id} \#{pane_id}")

    case result do
      {:ok, [^pane_id | _]} -> :alive
      other -> {:missing, other}
    end
  end

  @spec capture_pane_dump(String.t()) :: String.t()
  def capture_pane_dump(pane_id) do
    case Tmux.command(Tmux, "capture-pane -p -t #{pane_id}") do
      {:ok, lines} -> lines |> Enum.take(8) |> Enum.join(" \\ ")
      _ -> "capture_failed"
    end
  end

  @spec pipe_pane_path(integer()) :: String.t()
  def pipe_pane_path(slot_index),
    do: "/tmp/aiur-debug/slot-#{slot_index}-attach.log"

  @spec debug_mode?() :: boolean()
  def debug_mode? do
    case System.get_env("AIUR_DEBUG") do
      v when is_binary(v) -> String.downcase(String.trim(v)) in ["1", "true", "yes"]
      _ -> false
    end
  end

  @spec dump_pipe_tail(integer()) :: :ok
  def dump_pipe_tail(slot_index) do
    path = pipe_pane_path(slot_index)

    case File.read(path) do
      {:ok, content} ->
        lines = String.split(content, "\n", trim: true)
        tail = lines |> Enum.take(-60) |> Enum.join(" \\ ")

        Logger.warning("opencode_slot phase=pipe_pane_tail slot=#{slot_index} path=#{path} lines=#{length(lines)} tail=#{inspect(tail)}")

      _ ->
        Logger.warning("opencode_slot phase=pipe_pane_tail slot=#{slot_index} path=#{path} status=unreadable")
    end

    :ok
  end

  # tmux pipe-pane captures every byte tmux writes to the pane to a
  # per-slot log file, so when opencode-attach dies we can read the
  # last bytes it emitted — including any stderr / panic / disconnect
  # message — instead of guessing. Gated behind AIUR_DEBUG=1.
  @spec maybe_start_pipe_pane(integer(), String.t()) :: :ok
  def maybe_start_pipe_pane(slot_index, pane_id) when is_binary(pane_id) do
    if debug_mode?() do
      path = pipe_pane_path(slot_index)
      _ = File.mkdir_p(Path.dirname(path))
      # `-o` only opens the pipe if one isn't already active for this
      # pane. The shell command appends every byte tmux writes to the
      # pane into the per-slot log file, so the very last bytes
      # opencode-attach emits before death are preserved on disk.
      _ = Tmux.command(Tmux, "pipe-pane -o -t #{pane_id} \"cat >> #{path}\"")

      Logger.info("opencode_slot phase=pipe_pane_started slot=#{slot_index} pane_id=#{pane_id} path=#{path}")
    end

    :ok
  end

  def maybe_start_pipe_pane(_slot_index, _pane_id), do: :ok

  # Redistribute pane widths across the hidden window so the keep-alive
  # sentinel pane never shrinks below tmux's minimum splittable width.
  # Without this, repeated kill+split cycles (one per identifier_miss
  # rebuild + one per session-bound respawn) halve the sentinel pane
  # each time; after enough cycles tmux returns `no space for new pane`
  # and the slot gets stuck.
  @spec reflow_hidden_window(String.t()) :: :ok
  def reflow_hidden_window(keep_alive_pane) do
    # `even-horizontal` requires at least 2 panes; tolerate a 1-pane
    # window (would be just the sentinel) by ignoring layout errors.
    case Tmux.command(Tmux, "select-layout -t #{keep_alive_pane} even-horizontal") do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end

  @spec hidden_window_target() :: {:ok, String.t()} | {:error, term()}
  def hidden_window_target do
    case HiddenWindow.status() do
      :ready ->
        try do
          state = :sys.get_state(HiddenWindow, 1_000)
          {:ok, state.keep_alive_pane_id}
        catch
          _, reason -> {:error, {:hidden_window_state_unavailable, reason}}
        end

      :waiting ->
        {:error, :hidden_window_not_ready}

      :failed ->
        {:error, :hidden_window_failed}

      :disabled ->
        {:error, :hidden_window_disabled}
    end
  end
end
