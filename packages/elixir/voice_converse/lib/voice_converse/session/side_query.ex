defmodule VoiceConverse.Session.SideQuery do
  @moduledoc false

  alias VoiceConverse.{Session.Runtime, TranscriptStore}

  @spec answer(map(), String.t(), term(), String.t(), atom(), map()) :: map()
  def answer(state, id, ref, text, mode, usage) do
    :ok = TranscriptStore.append(state.store, record(state, id, ref, text, mode, usage))

    prefix =
      if mode == :replay and not state.replay_disclosed?,
        do: "The agent's summary says: ",
        else: "Here is what the agent's notes say: "

    state = state |> Runtime.consult_context(prefix <> text) |> VoiceConverse.LiveContext.announce(prefix <> text)
    %{state | replay_disclosed?: state.replay_disclosed? or mode == :replay}
  end

  defp record(state, id, ref, text, mode, usage) do
    %{
      type: "side_query",
      draft_id: id,
      fork_id: usage[:session_id] || usage["session_id"],
      query_ref: inspect(ref),
      fork_mode: mode,
      cost: usage[:cost_usd] || usage["cost_usd"],
      usage: usage,
      text: text,
      at: DateTime.to_iso8601(state.clock.())
    }
  end
end
