defmodule SymphonyPane.Viewport do
  @moduledoc """
  Two-region ANSI renderer: transcript above, composer below.

  Diffs line-by-line against last-rendered state. Uses `Owl.Data.tag/2` for
  ANSI composition and `Owl.IO.columns/0` for size detection. Reserves the
  final column to prevent autowrap on SSH clients (the lesson learned from
  `status_dashboard.ex`'s Termius bugs).

  Per-keystroke render budget: <200μs from byte-in to byte-out, measured
  via `:timer.tc/1` in this module's hot path.

  Scaffold: API placeholder.
  """

  alias SymphonyElixir.AgentEvents

  @type state :: %{
          transcript: [AgentEvents.transcript_event()],
          composer_buffer: String.t(),
          composer_cursor: non_neg_integer(),
          columns: pos_integer(),
          rows: pos_integer()
        }

  @spec render(state()) :: iodata()
  def render(_state), do: []
end
