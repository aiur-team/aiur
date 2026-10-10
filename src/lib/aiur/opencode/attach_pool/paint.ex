defmodule Aiur.Opencode.AttachPool.Paint do
  @moduledoc """
  Tmux geometry and paint-detect helpers retained for slot-bound callers
  (e.g. Slot's hidden-window setup) and as a stable target for behavioral
  guards. Not invoked from inside `Aiur.Opencode.AttachPool`.
  """

  alias Aiur.Opencode.SlotSupervisor
  alias Aiur.Tmux

  @paint_poll_interval_ms 100

  @doc """
  Re-size the hidden window so each slot's attach pane matches the
  geometry it will have in window 0 once the user opens it. Avoids
  the SIGWINCH that triggers opencode-attach's ~7 s splash animation
  on every move-pane resize. Idempotent — safe to call on terminal
  resize signals.

  `HiddenWindow.handle_continue(:create_window)` runs the same logic
  inline at boot so the keep-alive pane is already at the right size
  before the first slot splits into it. This `ensure_hidden_geometry`
  entry point is kept for re-trigger paths (e.g. terminal resize).
  """
  @spec ensure_hidden_geometry() :: :ok
  def ensure_hidden_geometry do
    with {:ok, [dims_str | _]} <-
           Tmux.command(
             Tmux,
             "display-message -p -t aiur-orangekid-default:0 \"\#{window_width} \#{window_height}\""
           ),
         [w_str, h_str] <- String.split(String.trim(dims_str), " ", trim: true),
         {term_w, ""} <- Integer.parse(w_str),
         {term_h, ""} <- Integer.parse(h_str) do
      slot_count = max(SlotSupervisor.slot_count(), 1)
      chat_pane_width = max(div(term_w, 2), 40)
      hidden_window_w = chat_pane_width * slot_count

      _ =
        Tmux.command(
          Tmux,
          "resize-window -t aiur-orangekid-default:aiur-hidden -x #{hidden_window_w} -y #{term_h}"
        )

      _ =
        Tmux.command(
          Tmux,
          "select-layout -t aiur-orangekid-default:aiur-hidden even-horizontal"
        )

      :ok
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc false
  @spec wait_for_paint(String.t(), non_neg_integer()) :: :ok | :timeout
  def wait_for_paint(pane_id, budget_ms) do
    deadline = System.monotonic_time(:millisecond) + budget_ms
    do_wait_for_paint(pane_id, deadline)
  end

  defp do_wait_for_paint(pane_id, deadline) do
    case Tmux.command(Tmux, "capture-pane -p -t #{pane_id}") do
      {:ok, lines} ->
        if String.contains?(Enum.join(lines, "\n"), "Build · issue-") do
          :ok
        else
          retry_wait_for_paint(pane_id, deadline)
        end

      _ ->
        retry_wait_for_paint(pane_id, deadline)
    end
  end

  defp retry_wait_for_paint(pane_id, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      :timeout
    else
      Process.sleep(@paint_poll_interval_ms)
      do_wait_for_paint(pane_id, deadline)
    end
  end
end
