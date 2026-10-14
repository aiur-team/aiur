defmodule Aiur.Opencode.Slot.Selection do
  @moduledoc """
  Session selection for `Aiur.Opencode.Slot`: ensure the identifier's session
  and respawn the slot's attach pane bound to it.
  """

  require Logger

  alias Aiur.Boot
  alias Aiur.Opencode.Protocol
  alias Aiur.Opencode.Slot.{AttachPane, Sessions, State}

  @doc false
  @spec do_select(String.t(), map()) :: {:ok, String.t(), map()} | {:error, term()}
  def do_select(identifier, state) do
    do_select_span = Aiur.Perf.span_begin(:slot_do_select, slot: state.slot_index, identifier: identifier)

    case Sessions.ensure_with_replay_span(identifier, state.base_url, state.slot_index, state.token) do
      {:ok, session_id} ->
        select_with_respawn(state, identifier, session_id, do_select_span)

      {:replay_failed, reason} ->
        span_kw = [result: :replay_failed, slot: state.slot_index, identifier: identifier, reason: reason]
        Aiur.Perf.span_end(do_select_span, span_kw)
        {:error, reason}

      {:writer_failed, err} ->
        Aiur.Perf.span_end(do_select_span, result: :writer_failed, slot: state.slot_index, identifier: identifier)
        err
    end
  end

  # Respawn opencode-attach with `--session <id>` so the TUI boots
  # straight into the conversation view. POSTing
  # `/tui/select-session` to an already-running pre-warmed attach
  # returns 200 but does not switch the rendered view — opencode
  # 1.15.6's TUI stays on the welcome screen ("Ask anything...",
  # OPENCODE logo). The previously-pre-warmed attach pane is killed
  # and a new one is split into aiur-hidden so PaneManager can
  # move it to visible. State.pane_id is updated to the new pane.
  defp select_with_respawn(state, identifier, session_id, do_select_span) do
    attach_cmd = Protocol.attach_command(state.base_url, session_id)

    case respawn_attach_with_session(state, session_id, attach_cmd) do
      {:ok, new_pane_id} ->
        Logger.info("opencode_slot phase=select elapsed_ms=#{Boot.elapsed_ms()} slot=#{state.slot_index} identifier=#{identifier} session_id=#{session_id} pane_id=#{new_pane_id}")
        span_kw = [slot: state.slot_index, identifier: identifier, session_id: session_id, pane_id: new_pane_id]
        Aiur.Perf.span_end(do_select_span, span_kw)
        {:ok, session_id, State.select_applied(state, identifier, session_id, new_pane_id)}

      {:error, _} = err ->
        Aiur.Perf.span_end(do_select_span, result: :respawn_failed, slot: state.slot_index, identifier: identifier)
        err
    end
  end

  defp respawn_attach_with_session(state, session_id, attach_cmd) do
    AttachPane.respawn_with_session(state, session_id, attach_cmd)
  end
end
