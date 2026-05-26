defmodule Aiur.Opencode.Style do
  @moduledoc """
  Chat-pane visual styling vocabulary.

  Centralizes the choice of dimming mechanism so that flipping from
  ANSI escapes to a Unicode marker (or markdown convention) only
  touches one site. Used by:

    * `Aiur.Opencode.ChatCompletions.format_delta/2` for live SSE
      deltas (commands, tool calls, reasoning)
    * `Aiur.Opencode.SessionWriter` for persisted event ticker rows
      (📥/📤/📄)

  ## Current choice: ANSI dim

  `\\e[2m…\\e[22m` (SGR "faint" / "decreased intensity"). opencode-attach
  is bubbletea/lipgloss-based and respects ANSI dim in supported
  terminals. The U5 probe in
  `docs/plans/2026-05-25-002-feat-chat-pane-followups-plan.md` verifies
  the mechanism renders distinctly in a real opencode-attach pane (not
  just `tmux capture-pane`, which honors ANSI at the cell-grid layer
  regardless of what bubbletea's renderer emitted).

  If the probe shows ANSI not honored, swap to the marker fallback by
  changing the implementation of `dim/1` to prepend `▸ ` instead of
  wrapping in escapes.
  """

  @ansi_dim_open "\e[2m"
  @ansi_dim_close "\e[22m"

  @doc """
  Wrap `text` in the dimming mechanism so it renders visibly subdued
  vs default-weight content (agent prose).
  """
  @spec dim(String.t()) :: String.t()
  def dim(text) when is_binary(text), do: @ansi_dim_open <> text <> @ansi_dim_close
end
