defmodule SymphonyPane.Composer do
  @moduledoc """
  Composer state machine: buffer, cursor position, history (later).

  On submit: (1) renders the user's message into the local transcript via
  optimistic update tagged with a client-generated `msg_id`, (2) calls
  `SymphonyElixir.PaneRPC.send_operator_message/2` via `:rpc.cast` so the
  composer does not block on network latency, (3) when the orchestrator's
  symmetric broadcast loops back through `"agent:<id>"` carrying the same
  `msg_id`, `SymphonyPane.Conversation` replaces the pending entry rather
  than duplicating.

  Length-caps input at 64 KiB and filters control characters except newline
  and tab before forwarding (defense-in-depth alongside server-side
  validation in `PaneRPC`).

  Scaffold: state shape settled; key dispatch and rendering land later.
  """

  @type state :: %{buffer: String.t(), cursor: non_neg_integer(), history: [String.t()]}

  @spec new() :: state()
  def new, do: %{buffer: "", cursor: 0, history: []}

  @spec append(state(), binary()) :: state()
  def append(state, _bytes), do: state

  @spec submit(state(), String.t()) :: {state(), {:submit, %{msg_id: String.t(), body: String.t()}}}
  def submit(state, _identifier) do
    {state, {:submit, %{msg_id: "", body: ""}}}
  end
end
