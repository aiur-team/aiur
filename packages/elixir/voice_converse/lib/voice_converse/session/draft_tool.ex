defmodule VoiceConverse.Session.DraftTool do
  @moduledoc false
  alias VoiceConverse.{Drafts, Tools, TranscriptStore}

  def instruction(state, params) do
    with {:ok, text} <- Tools.proposed_instruction(params),
         {:ok, draft, drafts} <-
           Drafts.propose_instruction(state.drafts, text,
             target: state.draft_target,
             at: DateTime.to_iso8601(state.clock.()),
             redactor: state.config.redactor
           ),
         record <- Drafts.record(draft),
         :ok <- TranscriptStore.append(state.store, record) do
      state.event_broadcast.(state.subscribers, state.id, {:draft, record})
      {Tools.draft_waiting(draft.draft_id), %{state | drafts: drafts}}
    else
      {:error, %{} = result} -> {result, state}
      {:error, reason} -> {Tools.draft_error(reason), state}
    end
  end
end
