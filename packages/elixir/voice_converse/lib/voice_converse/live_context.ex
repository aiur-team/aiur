defmodule VoiceConverse.LiveContext do
  @moduledoc """
  Session-owned live context, independent of the host event bus.

  Ports send `{:briefing, %Briefing{}}`, `{:context_update, text, opts}` (with
  `announce: true` for refreshed notes), `{:command_resolved, id}`, `:target_gone`,
  or `:live_context_unavailable` when an established subscription is lost
  to their subscribed pid. Unknown messages are left to the consult handler.
  Every update is redacted and appended before delivery. Provider updates are
  coalesced over five seconds; the last ten milestones remain available in state.
  """

  alias VoiceConverse.{Briefing, Drafts, Ports, TranscriptStore}
  alias VoiceConverse.Session.Runtime

  @interval_ms 5_000

  def attach(state) do
    owner = self()

    results =
      for port <- [state.config.briefing_source, state.config.agent_channel, state.config.command_source],
          not is_nil(port) do
        Ports.call_port(port, :subscribe, [state.target, owner], :ask)
      end

    briefing =
      case Map.get(state, :initial_briefing) do
        {:ok, %Briefing{} = initial} -> initial
        nil -> read_briefing(state)
        _ -> nil
      end

    live = %{
      briefing: briefing,
      pending: [],
      announcements: [],
      timer: nil,
      last_sent: nil,
      events: [],
      refreshes: %{},
      fallback?: Enum.any?(results, &(&1 not in [:ok, :not_applicable]))
    }

    state = Map.put(state, :live_context, live)

    state =
      if live.fallback? do
        text = "Gaps: Live updates unavailable for one or more sources; refresh on tool calls"
        record!(state, text, "events")
        %{state | context: state.context <> "\n" <> text}
      else
        state
      end

    # Catch a change between the opening read and the subscription being installed.
    refresh_briefing(state)
  end

  def refresh(%{live_context: %{fallback?: true}} = state), do: refresh_briefing(state)
  def refresh(state), do: state

  @doc false
  @spec refresh_briefing(map(), pid(), term()) :: {:noreply, map()}
  def refresh_briefing(state, session, caller) do
    ref = make_ref()
    config = state.config
    target = state.target

    Task.start(fn ->
      result = Ports.call_port(config.briefing_source, :brief, [target], :brief)
      send(session, {:briefing_refresh, ref, result})
    end)

    {:noreply, put_in(state.live_context.refreshes[ref], caller)}
  end

  defp refresh_briefing(state) do
    case read_briefing(state) do
      %Briefing{} = briefing -> update_briefing(state, briefing)
      _ -> state
    end
  end

  def handle_info(_message, %{finishing?: true} = state), do: {:noreply, state}
  def handle_info(_message, %{finished?: true} = state), do: {:noreply, state}

  def handle_info({:briefing_refresh, ref, result}, state),
    do: complete_refresh(state, ref, result)

  def handle_info({:briefing, %Briefing{} = briefing}, state),
    do: {:noreply, update_briefing(state, briefing)}

  def handle_info({:context_update, text, opts}, state) when is_binary(text) and is_list(opts),
    do: {:noreply, enqueue(state, text, Keyword.get(opts, :announce, false))}

  def handle_info({:command_resolved, id}, state) when is_binary(id) do
    state = stale_drafts(state, id)
    {:noreply, enqueue(state, "Command #{id} resolved", false)}
  end

  def handle_info(:live_context_unavailable, state) do
    state = put_in(state.live_context.fallback?, true)
    {:noreply, enqueue(state, "Gaps: Live updates unavailable; refresh on tool calls", false)}
  end

  def handle_info(:target_gone, state) do
    # Ending goes through the normal session close path, including transcript cleanup.
    send(self(), {:live_target_gone, :target_gone})
    {:noreply, state}
  end

  def handle_info({:live_context_flush, token}, %{live_context: %{timer: {_timer, token}}} = state) do
    state = put_in(state.live_context.timer, nil)
    {:noreply, flush(state)}
  end

  def handle_info({:live_context_flush, _old_token}, state), do: {:noreply, state}
  def handle_info(message, state), do: VoiceConverse.Session.Consult.handle_info(message, state)

  def ready(state), do: flush(state)

  def announce(%{provider_ref: nil} = state, text),
    do: update_in(state.live_context.announcements, &Enum.take(Enum.uniq(&1 ++ [text]), -10))

  def announce(%{state: status} = state, text) when status in [:connecting, :reconnecting],
    do: update_in(state.live_context.announcements, &Enum.take(Enum.uniq(&1 ++ [text]), -10))

  def announce(state, text) do
    if function_exported?(state.provider, :announce, 3),
      do: state.provider.announce(state.provider_ref, text, when: :idle)

    state
  rescue
    _ -> state
  catch
    :exit, _ -> state
  end

  defp update_briefing(state, briefing) do
    previous = state.live_context.briefing || %Briefing{}
    lines = Briefing.diff(previous, briefing)
    state = put_in(state.live_context.briefing, briefing)

    if lines == [], do: state, else: enqueue_briefing(state, Enum.join(lines, "\n"))
  end

  defp enqueue(state, text, announce?) do
    text = state.config.redactor.(text)
    enqueue_redacted(state, text, announce?, "events")
  end

  defp enqueue_briefing(state, text) do
    text =
      text
      |> state.config.redactor.()
      |> limit(state.config.limits.briefing_token_budget)

    enqueue_redacted(state, text, false, "briefing")
  end

  defp enqueue_redacted(state, text, announce?, source) do
    record!(state, text, source)
    state = update_in(state.live_context.events, &Enum.take(&1 ++ [text], -10))
    state = update_in(state.live_context.pending, &Enum.take(Enum.uniq(&1 ++ [text]), -10))

    state =
      if announce?,
        do: update_in(state.live_context.announcements, &Enum.take(Enum.uniq(&1 ++ [text]), -10)),
        else: state

    flush(state)
  end

  defp flush(%{provider_ref: nil} = state), do: state
  defp flush(%{state: status} = state) when status in [:connecting, :reconnecting], do: state

  defp flush(%{live_context: %{pending: []}} = state) do
    Enum.each(state.live_context.announcements, &announce(state, &1))
    put_in(state.live_context.announcements, [])
  end

  defp flush(state) do
    elapsed =
      if state.live_context.last_sent,
        do: DateTime.diff(state.clock.(), state.live_context.last_sent, :millisecond),
        else: @interval_ms

    if elapsed >= @interval_ms do
      text = Enum.join(state.live_context.pending, "\n")

      case state.provider.send_context(state.provider_ref, text) do
        :ok ->
          Enum.each(state.live_context.announcements, &announce(state, &1))
          if state.live_context.timer, do: Runtime.cancel_timer(elem(state.live_context.timer, 0))

          %{
            state
            | live_context: %{
                state.live_context
                | pending: [],
                  announcements: [],
                  timer: nil,
                  last_sent: state.clock.()
              }
          }

        _ ->
          schedule(put_in(state.live_context.last_sent, state.clock.()), @interval_ms)
      end
    else
      schedule(state, @interval_ms - elapsed)
    end
  end

  defp schedule(%{live_context: %{timer: nil}} = state, delay) do
    token = make_ref()
    timer = state.schedule_after.(delay, {:live_context_flush, token})
    put_in(state.live_context.timer, {timer, token})
  end

  defp schedule(state, _delay), do: state

  defp stale_drafts(state, _command_id) do
    Enum.reduce(state.drafts.drafts, state, fn {id, draft}, state ->
      # Unconfirmed instructions were composed against the old Command context.
      if draft.status == :proposed and draft.kind == :instruction do
        {:ok, draft, drafts} = Drafts.transition(state.drafts, id, :stale, at: now(state))
        :ok = TranscriptStore.append(state.store, Drafts.record(draft))
        state.event_broadcast.(state.subscribers, state.id, {:draft, Drafts.record(draft)})
        %{state | drafts: drafts}
      else
        state
      end
    end)
  end

  defp read_briefing(state) do
    case Ports.call_port(state.config.briefing_source, :brief, [state.target], :brief) do
      {:ok, %Briefing{} = briefing} -> briefing
      _ -> nil
    end
  end

  defp complete_refresh(state, ref, result) do
    case Map.pop(state.live_context.refreshes, ref) do
      {nil, _refreshes} ->
        {:noreply, state}

      {caller, refreshes} ->
        state = put_in(state.live_context.refreshes, refreshes)

        case result do
          {:ok, %Briefing{} = briefing} ->
            state = update_briefing(state, briefing)
            GenServer.reply(caller, :ok)
            {:noreply, state}

          _ ->
            GenServer.reply(caller, {:error, :unavailable})
            {:noreply, state}
        end
    end
  end

  defp limit(text, budget) do
    max_bytes = budget * 4

    if byte_size(text) <= max_bytes do
      text
    else
      take_graphemes(text, max_bytes, [])
    end
  end

  defp take_graphemes(text, remaining, acc) do
    case String.next_grapheme(text) do
      {grapheme, rest} when byte_size(grapheme) <= remaining ->
        take_graphemes(rest, remaining - byte_size(grapheme), [grapheme | acc])

      _ ->
        acc |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  defp record!(state, text, "briefing") do
    :ok =
      TranscriptStore.append(state.store, %{
        type: "context",
        source: "briefing",
        ref: target_ref(state),
        observed_at: now(state),
        text: text,
        refresh?: true
      })
  end

  defp record!(state, text, source) do
    :ok = TranscriptStore.append(state.store, %{type: "context", source: source, text: text, at: now(state)})
  end

  defp target_ref(state) do
    target = Map.get(state, :draft_target, %{})
    target |> Map.get(:id, Map.get(target, "id", "target")) |> to_string()
  end

  defp now(state), do: DateTime.to_iso8601(state.clock.())
end
