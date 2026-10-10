defmodule Aiur.Opencode.SessionWriter.EventRows do
  @moduledoc """
  Cross-ticket event ticker rows and write-failure bookkeeping for
  `Aiur.Opencode.SessionWriter` (R2 from the chat-pane follow-ups plan).

  Every function takes the writer state and returns either the next state
  or the `GenServer` reply tuple the writer hands straight back.
  """

  require Logger

  alias Aiur.Opencode.{EventRow, SessionWriter}
  alias Aiur.Opencode.SessionWriter.TranscriptWrite

  @fk_failure_stop_threshold 5

  # Soft cap for `seen_event_ids` — matches the IssueLog history-pull
  # window. Older ids may evict; very-late re-deliveries beyond the cap
  # could double-write (acceptable failure mode given DebugLog's
  # in-process broadcast contract).
  @seen_event_ids_cap 500

  @type reply :: {:noreply, SessionWriter.t()} | {:stop, atom(), SessionWriter.t()}

  @spec handle_matching_event_debug(SessionWriter.t(), map()) :: reply()
  def handle_matching_event_debug(state, entry) do
    id = Map.get(entry, :id)

    cond do
      is_nil(id) ->
        # No event id → no dedup possible. Render anyway; the in-memory
        # MapSet only protects against re-deliveries, not first writes.
        write_event_row(state, entry)

      MapSet.member?(state.seen_event_ids, id) ->
        {:noreply, state}

      true ->
        # Only remember the id when the write actually landed (no_reply
        # path). If write_event_row returned a stop, the FK threshold
        # tripped and we shouldn't pretend the event was persisted.
        case write_event_row(state, entry) do
          {:noreply, new_state} -> {:noreply, remember_event_id(new_state, id)}
          {:stop, _reason, _new_state} = stop -> stop
        end
    end
  end

  defp write_event_row(state, entry) do
    case EventRow.from(entry, state.identifier) do
      nil ->
        {:noreply, state}

      body ->
        case TranscriptWrite.write_system_standalone(state, body) do
          {:ok, _message_id} ->
            # Reset the FK counter so a healthy event-row stream after
            # a transient FK burst doesn't leave the counter armed.
            {:noreply, reset_fk_failures(state)}

          {:error, reason} ->
            log_session_write_failure(
              "event_row_failed",
              state.identifier,
              reason,
              kind: inspect(entry[:kind])
            )

            handle_write_failure(state, reason)
        end
    end
  end

  # FOREIGN KEY violations land here when opencode's SQL session row has
  # been deleted out from under us — usually because Aiur.Shutdown is
  # tearing down sessions while events are still in flight, or because
  # the slot respawned and the writer hasn't been notified yet. Neither
  # is a real failure; demote those to debug so the warning-level
  # surface stays signal-only. Other write failures still warn.
  @spec log_session_write_failure(String.t(), String.t(), term(), keyword()) :: :ok
  def log_session_write_failure(tag, identifier, reason, extra \\ []) do
    extras = extra |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{v}" end)
    msg = "opencode_session_writer #{tag} identifier=#{identifier} #{extras} reason=#{inspect(reason)}"

    if foreign_key_violation?(reason) do
      Logger.debug(msg)
    else
      Logger.warning(msg)
    end
  end

  defp foreign_key_violation?(%Exqlite.Error{message: msg}) when is_binary(msg),
    do: String.contains?(msg, "FOREIGN KEY")

  defp foreign_key_violation?(_), do: false

  # Bump the FK-failure counter when the failure was an FK violation
  # (session gone), stop the writer once we cross the threshold.
  # Non-FK errors are transient — log and keep running.
  @spec handle_write_failure(SessionWriter.t(), term()) :: reply()
  def handle_write_failure(state, reason) do
    if foreign_key_violation?(reason) do
      bumped = Map.update(state, :consecutive_fk_failures, 1, &(&1 + 1))

      if bumped.consecutive_fk_failures >= @fk_failure_stop_threshold do
        Logger.info("opencode_session_writer stopping identifier=#{state.identifier} reason=session_reaped fk_failures=#{bumped.consecutive_fk_failures}")

        {:stop, :normal, bumped}
      else
        {:noreply, bumped}
      end
    else
      {:noreply, state}
    end
  end

  @spec reset_fk_failures(SessionWriter.t()) :: SessionWriter.t()
  def reset_fk_failures(state) do
    case Map.get(state, :consecutive_fk_failures, 0) do
      0 -> state
      _ -> Map.put(state, :consecutive_fk_failures, 0)
    end
  end

  defp remember_event_id(state, id) do
    seen = MapSet.put(state.seen_event_ids, id)

    seen =
      if MapSet.size(seen) > @seen_event_ids_cap do
        # Cap exceeded — drop a single arbitrary element. MapSet eviction
        # isn't strictly ordered but the cap exists only to bound memory;
        # very-late re-deliveries beyond the cap could double-write
        # (acceptable per the plan's risk table).
        {dropped, smaller} = pop_any(seen)
        _ = dropped
        smaller
      else
        seen
      end

    %{state | seen_event_ids: seen}
  end

  defp pop_any(set) do
    [first | _] = MapSet.to_list(set)
    {first, MapSet.delete(set, first)}
  end
end
