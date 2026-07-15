defmodule Aiur.PaneManager.ScreenGrab do
  @moduledoc """
  AIUR_SCREEN_GRAB diagnostics loop helpers for PaneManager.
  """

  require Logger

  alias Aiur.{Boot, Tmux}
  alias Aiur.PaneManager.State

  # Periodic screen-grab interval. Captures every tracked pane's content into the
  # log so post-mortem reviews can replay the visible state at each tick. Gated
  # behind its OWN flag (AIUR_SCREEN_GRAB), NOT AIUR_DEBUG: each tick forks one
  # `capture-pane` per pane, so at high ticket counts it piles FD pressure onto a
  # --debug run — and --debug must stay safe to leave on. Turn this on only when
  # you specifically need pane snapshots.
  @screen_grab_interval_ms 2_000
  @screen_grab_max_lines 8

  @spec interval_ms() :: pos_integer()
  def interval_ms, do: @screen_grab_interval_ms

  @spec log_screen_grab(State.t()) :: :ok
  def log_screen_grab(state) do
    panes = collect_tracked_panes(state)

    Logger.info("aiur_screen_grab phase=tick pane_count=#{map_size(panes)} elapsed_ms=#{Boot.elapsed_ms()}")

    Enum.each(panes, fn {pane_id, label} ->
      log_pane_grab(pane_id, label, Tmux.command(state.tmux, "capture-pane -p -t #{pane_id}"))
    end)
  end

  defp log_pane_grab(pane_id, label, {:ok, lines}) do
    excerpt =
      lines
      |> Enum.take(@screen_grab_max_lines)
      |> Enum.map(&String.trim_trailing/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" \\ ")

    Logger.info("aiur_screen_grab pane_id=#{pane_id} label=#{label} content=#{inspect(excerpt)}")
  end

  defp log_pane_grab(pane_id, label, {:error, reason}) do
    # Once a Claude session restart (or a forced Executor restart)
    # kills the tmux server but leaves the BEAM running, every 2s
    # tick produces three log lines — the warning from Tmux.command
    # plus the schedule + grab info pair. Demote to debug when the
    # server is gone so the log isn't flooded with the same dead-
    # server message until the next Executor reboot.
    if dead_tmux?(reason) do
      Logger.debug("aiur_screen_grab pane_id=#{pane_id} label=#{label} error=#{inspect(reason)}")
    else
      Logger.info("aiur_screen_grab pane_id=#{pane_id} label=#{label} error=#{inspect(reason)}")
    end
  end

  # `Aiur.Tmux.command/2` returns `{:error, trimmed_stderr}` on failure.
  # tmux's "no server running on …" is the canonical signal that the
  # server died after the BEAM connected.
  @spec dead_tmux?(term()) :: boolean()
  def dead_tmux?(reason) when is_binary(reason),
    do: String.contains?(reason, "no server running")

  def dead_tmux?(_), do: false

  @spec collect_tracked_panes(State.t()) :: %{optional(String.t()) => String.t()}
  def collect_tracked_panes(state) do
    base =
      if is_binary(state.agent_list_pane) do
        %{state.agent_list_pane => "agent_list"}
      else
        %{}
      end

    Enum.reduce(state.slot_panes, base, fn
      {slot, pane_id}, acc when is_binary(pane_id) ->
        identifier = Map.get(state.pane_to_identifier, pane_id, "?")
        Map.put(acc, pane_id, "slot#{slot}:#{identifier}")

      _, acc ->
        acc
    end)
  end

  # Whether the per-pane screen-grab capture loop runs. Deliberately separate
  # from AIUR_DEBUG so a --debug run gets full structured logs WITHOUT the
  # per-pane `capture-pane` fork loop that scales with ticket count.
  @spec screen_grab?() :: boolean()
  def screen_grab? do
    case System.get_env("AIUR_SCREEN_GRAB") do
      value when is_binary(value) ->
        String.downcase(String.trim(value)) in ["1", "true", "yes"]

      _ ->
        false
    end
  end
end
