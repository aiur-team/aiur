defmodule Aiur.Claude.Transcript do
  @moduledoc """
  Claude-side counterpart to `Aiur.Codex.Transcript`.

  Out of scope for the current chat-pane native-parity work — Claude
  notification shapes differ (`item/created`, `item/progress`, tool_call
  / tool_result item types) and are surfaced by `Aiur.Claude.EventHumanizer`
  for log output today. When chat-pane parity for Claude becomes scope,
  port the codex extraction shape here: read the Claude-native fields,
  return `Aiur.AgentEvents.transcript_event/3` values, and the rest of
  the SessionWriter / opencode-row pipeline keeps working unchanged.

  Until then, returning `:skip` lets `Aiur.AgentRunner.transcript_event_from/2`
  fall back to its universal legacy path (event-kind-based role mapping).
  """

  alias Aiur.AgentEvents

  @spec extract(map(), String.t() | nil) :: {:ok, AgentEvents.transcript_event()} | :skip
  def extract(_message, _fallback_turn_id), do: :skip
end
