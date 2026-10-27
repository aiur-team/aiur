defmodule VoiceConverse.Session.Confirmation do
  @moduledoc false

  alias VoiceConverse.{Drafts, TranscriptStore}

  def handle_call(action, _from, state, draft_id, opts) do
    case call(action, state, draft_id, opts) do
      {:ok, draft, state} -> {:reply, {:ok, draft}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def call(_action, state, _draft_id, opts) when not is_list(opts), do: {:error, :not_client, state}

  def call(:confirm_draft, state, draft_id, opts) do
    if Keyword.get(opts, :origin) == :client,
      do: confirm(state, draft_id, opts),
      else: {:error, :not_client, state}
  end

  def call(:discard_draft, state, draft_id, opts) do
    if Keyword.get(opts, :origin) == :client,
      do: discard(state, draft_id),
      else: {:error, :not_client, state}
  end

  defp confirm(state, draft_id, opts) do
    with {:ok, draft} <- Drafts.fetch(state.drafts, draft_id),
         :ok <- confirmable?(state, draft),
         {:ok, state} <- edit(state, draft, opts),
         {:ok, draft, drafts} <- Drafts.confirm(state.drafts, draft_id, client_identity(opts), at: now(state)),
         {:ok, state} <- persist_draft(state, draft) do
      deliver(%{state | drafts: drafts}, draft)
    else
      :confirmed -> confirmed(state, draft_id)
      :stale -> stale(state, draft_id)
      {:error, reason} -> {:error, reason, state}
      _ -> {:error, :unknown, state}
    end
  end

  defp discard(state, draft_id) do
    with {:ok, draft, drafts} <- Drafts.transition(state.drafts, draft_id, :discarded, at: now(state)),
         {:ok, state} <- persist_draft(state, draft) do
      {:ok, draft, %{state | drafts: drafts}}
    else
      {:error, reason} -> {:error, reason, state}
      _ -> {:error, :unknown, state}
    end
  end

  defp confirmable?(%{config: %{agent_channel: nil}}, _draft), do: {:error, :capability_unavailable}
  defp confirmable?(_state, %{status: :confirmed}), do: :confirmed
  defp confirmable?(_state, %{status: :failed}), do: :ok
  defp confirmable?(_state, %{status: :stale}), do: :stale

  defp confirmable?(state, %{status: :proposed}) do
    if state.config.briefing_source.alive?(state.target) == false, do: :stale, else: :ok
  rescue
    _error -> :ok
  end

  defp confirmable?(_state, _draft), do: {:error, :invalid_transition}

  defp stale(state, draft_id) do
    with {:ok, draft, drafts} <- Drafts.transition(state.drafts, draft_id, :stale, at: now(state)),
         {:ok, state} <- persist_draft(state, draft) do
      {:error, :target_stale, %{state | drafts: drafts}}
    else
      _ -> {:error, :unknown, state}
    end
  end

  defp confirmed(state, draft_id) do
    case Drafts.fetch(state.drafts, draft_id) do
      {:ok, draft} -> {:ok, draft, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp edit(state, draft, opts) do
    if Keyword.has_key?(opts, :edited_text) do
      with {:ok, edited, drafts} <-
             Drafts.edit(state.drafts, draft.draft_id, opts[:edited_text],
               at: now(state),
               redactor: state.config.redactor
             ),
           {:ok, state} <- persist_draft(state, edited) do
        {:ok, %{state | drafts: drafts}}
      end
    else
      {:ok, state}
    end
  end

  defp persist_draft(state, draft) do
    record = Drafts.record(draft)

    case TranscriptStore.append(state.store, record) do
      :ok ->
        state.event_broadcast.(state.subscribers, state.id, {:draft, record})
        {:ok, state}

      {:error, _reason} ->
        {:error, state}
    end
  end

  defp deliver(state, draft) do
    case state.config.agent_channel.instruct(state.target, draft.text, draft.draft_id, []) do
      {:ok, _delivery_id} -> {:ok, draft, state}
      {:error, reason} -> fail_delivery(state, draft, reason)
      _ -> fail_delivery(state, draft, :unknown)
    end
  end

  defp fail_delivery(state, draft, reason) do
    with {:ok, failed, drafts} <- Drafts.transition(state.drafts, draft.draft_id, :failed, at: now(state)),
         {:ok, state} <- persist_draft(state, failed) do
      {:error, reason, %{state | drafts: drafts}}
    else
      _ -> {:error, reason, state}
    end
  end

  defp client_identity(opts), do: %{source: :client_socket, principal: Keyword.get(opts, :principal, %{})}
  defp now(state), do: DateTime.to_iso8601(state.clock.())
end
