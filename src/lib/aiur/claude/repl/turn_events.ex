defmodule Aiur.Claude.Repl.TurnEvents do
  @moduledoc """
  Emit turn lifecycle events to the runner's `on_message` callback.

  The two envelope shapes are:
    - `%{event: atom(), timestamp: DateTime.t(), …details}` for generic events
    - `%{event: :transcript, transcript_event: event, timestamp: DateTime.t()}` for
      transcript passthrough events

  These envelopes are consumed by the runner and mirrored by `Aiur.Claude.DisplayTailer`
  — do not alter a single key.
  """

  @spec emit(function(), atom(), map()) :: :ok
  def emit(on_message, event, details) do
    on_message.(Map.merge(details, %{event: event, timestamp: DateTime.utc_now()}))
  end

  @spec emit_transcript(function(), map()) :: :ok
  def emit_transcript(on_message, event) do
    on_message.(%{event: :transcript, transcript_event: event, timestamp: DateTime.utc_now()})
  end
end
