defmodule VoiceConverse.Session.Consult do
  @moduledoc false

  alias VoiceConverse.{Drafts, Ports, TranscriptStore}
  alias VoiceConverse.Session.Confirmation
  alias VoiceConverse.Session.Runtime

  @framing "Question from the operator's voice assistant. Answer briefly. This is not an instruction; do not change your plan."

  def redact_question(state, params) when is_map(params) do
    Map.new(params, fn {key, value} ->
      {key, if(key in ["question", :question] and is_binary(value), do: state.config.redactor.(value), else: value)}
    end)
  end

  def redact_question(_state, _params), do: %{}

  def tool(%{consult: consult} = state, _params) when not is_nil(consult),
    do: {result("A question is already waiting.", true), state}

  def tool(%{config: %{agent_channel: nil}} = state, _params),
    do: {result("Agent channel unavailable.", true), state}

  def tool(state, params) when not is_map(params), do: {result("A question is required.", true), state}

  def tool(state, params) do
    capabilities = Ports.call_port(state.config.agent_channel, :capabilities, [state.target], :ask)
    kind = Map.get(params, "question_type", Map.get(params, :question_type))

    case capabilities do
      %{ask: true} ->
        propose(state, params)

      %{fork: fork} when kind == "history" and fork in [:native, :history_copy, :replay] ->
        propose(state, params)

      %{fork: fork} when fork in [:native, :history_copy, :replay] ->
        {result("Queued agent questions are unavailable.", true), state}

      _ ->
        {result("Agent channel unavailable.", true), state}
    end
  end

  defp propose(state, params) do
    question = Map.get(params, "question", Map.get(params, :question))

    with {:ok, draft, drafts} <-
           Drafts.propose_consult(state.drafts, question,
             target: state.draft_target,
             at: now(state),
             redactor: state.config.redactor
           ),
         :ok <- persist(state, draft) do
      route =
        if Map.get(params, "question_type", Map.get(params, :question_type)) == "history", do: :history, else: :fresh

      timer = state.schedule_after.(60_000, {:consult_confirm_progress, draft.draft_id})

      state = %{
        state
        | drafts: drafts,
          consult: %{id: draft.draft_id, phase: :proposed, route: route, progress_timer: timer}
      }

      state = set_state(state, :consulting)

      if confirm?(state) do
        {result("Question #{draft.draft_id} is waiting for the operator to confirm."), state}
      else
        case Confirmation.call(:confirm_draft, state, draft.draft_id, origin: :client) do
          {:ok, _draft, state} ->
            {result("Asked. I'll tell you when it answers."), state}

          {:error, :outcome_unknown, state} ->
            {result("Delivery is uncertain; the agent may still receive the question.", true), state}

          {:error, _reason, state} ->
            {result("Unable to ask the agent.", true), state}
        end
      end
    else
      _ -> {result("Unable to create a question.", true), state}
    end
  end

  def deliver(state, draft) do
    channel = state.config.agent_channel
    VoiceConverse.Session.Runtime.cancel_timer(state.consult[:progress_timer])

    case Ports.call_port(channel, :subscribe, [state.target, self()], :ask) do
      :ok -> route_question(state, draft, channel)
      _ -> {:error, :unavailable, state}
    end
  end

  defp route_question(%{consult: %{route: :history}} = state, draft, channel) do
    capabilities = Ports.call_port(channel, :capabilities, [state.target], :ask)

    if is_map(capabilities) and Map.get(capabilities, :fork, :none) in [:native, :history_copy, :replay] do
      fork_question =
        "Answer the operator's question from what you already know. Do not change files.\n\n" <> draft.text

      case Ports.call_port(
             channel,
             :fork_query,
             [state.target, fork_question, [ref: draft.draft_id, origin: :voice_assistant]],
             :ask
           ) do
        {:ok, ref} ->
          _ = state.schedule_after.(60_000, {:consult_fork_timeout, draft.draft_id, ref})

          state = %{
            state
            | consult: %{id: draft.draft_id, delivery_id: ref, phase: :fork_waiting, fork_mode: capabilities.fork},
              consult_confirmed?: true
          }

          {:ok, draft, set_state(state, :consulting)}

        _ ->
          fallback_question(state, draft, channel, capabilities)
      end
    else
      fallback_question(state, draft, channel, capabilities)
    end
  end

  defp route_question(state, draft, channel) do
    capabilities = Ports.call_port(channel, :capabilities, [state.target], :ask)
    fallback_question(state, draft, channel, capabilities)
  end

  defp fallback_question(state, draft, channel, %{ask: true}), do: send_question(state, draft, channel)
  defp fallback_question(state, _draft, _channel, _capabilities), do: {:error, :unsupported, state}

  defp send_question(state, draft, channel) do
    text = @framing <> "\n\n" <> draft.text

    case Ports.call_port(
           channel,
           :ask,
           [state.target, text, draft.draft_id, [delivery_policy: :checkpoint, origin: :voice_assistant]],
           :ask
         ) do
      {:ok, delivery_id} ->
        timer =
          state.schedule_after.(state.config.limits.consult_timeout_seconds * 1_000, {:consult_timeout, draft.draft_id})

        _ = state.schedule_after.(60_000, {:consult_progress, draft.draft_id})

        state = %{
          state
          | consult: %{id: draft.draft_id, delivery_id: delivery_id, phase: :waiting, timer: timer},
            consult_confirmed?: true
        }

        state = set_state(state, :consulting)

        state =
          if async_listener?(state, channel),
            do: Runtime.consult_context(state, "The agent will see the question when it next reads its messages."),
            else: state

        {:ok, draft, state}

      {:error, reason} when reason in [:unavailable, :timeout, :outcome_unknown] ->
        unknown_delivery(state, draft)

      {:error, reason} ->
        {:error, reason, state}

      _ ->
        unknown_delivery(state, draft)
    end
  end

  defp unknown_delivery(state, draft) do
    state = try_transition_unknown(state, draft.draft_id)
    _ = state.schedule_after.(60_000, {:consult_unknown_progress, draft.draft_id})
    state = %{state | consult: %{id: draft.draft_id, phase: :unknown}, consult_confirmed?: true}

    state =
      state
      |> set_state(:consulting)
      |> Runtime.consult_context("Delivery is uncertain; the agent may still receive the question.")

    {:error, :outcome_unknown, state}
  end

  defp try_transition_unknown(state, id) do
    transition(state, id, :unknown)
  rescue
    _error -> state
  catch
    _kind, _reason -> state
  end

  def handle_info(message, state) do
    {:noreply, event(message, state)}
  rescue
    _error -> {:noreply, state, {:continue, :consult_failed}}
  catch
    _kind, _reason -> {:noreply, state, {:continue, :consult_failed}}
  end

  def event(_message, %{finishing?: true} = state), do: state
  def event(_message, %{finished?: true} = state), do: state

  def event({:agent_reply, ref, text}, %{consult: %{id: id, delivery_id: ref, phase: :waiting}} = state)
      when is_binary(text) do
    text = state.config.redactor.(text)
    persist_answer!(state, id, text, :agent)
    state = transition(state, id, :sent) |> transition(id, :delivered)
    state = Runtime.consult_context(state, "The agent answered: " <> text)
    state |> Map.put(:consult, nil) |> set_state(:listening)
  end

  def event(
        {:fork_answer, ref, text},
        %{consult: %{id: id, delivery_id: ref, phase: :fork_waiting, fork_mode: mode}} = state
      )
      when is_binary(text) do
    text = state.config.redactor.(text)
    persist_answer!(state, id, text, :fork)
    state = transition(state, id, :sent) |> transition(id, :delivered)
    prefix = if mode == :replay, do: "The agent's summary says: ", else: "Here is what the agent's notes say: "
    state = Runtime.consult_context(state, prefix <> text)
    state |> Map.put(:consult, nil) |> set_state(:listening)
  end

  def event({:consult_fork_timeout, id, ref}, %{consult: %{id: id, delivery_id: ref, phase: :fork_waiting}} = state) do
    {:ok, draft} = Drafts.fetch(state.drafts, id)

    if target_ended?(state) do
      state
      |> transition(id, :stale)
      |> Runtime.consult_context("The agent has ended; the question is stale.")
      |> Map.put(:consult, nil)
      |> set_state(:listening)
    else
      channel = state.config.agent_channel
      capabilities = Ports.call_port(channel, :capabilities, [state.target], :ask)

      state =
        if match?(%{ask: true}, capabilities),
          do: Runtime.consult_context(state, "The side question did not answer; asking the agent instead."),
          else: state

      case fallback_question(state, draft, channel, capabilities) do
        {:ok, _draft, state} ->
          state

        {:error, :outcome_unknown, state} ->
          state

        {:error, _reason, state} ->
          state
          |> transition(id, :failed)
          |> Runtime.consult_context("The question could not be delivered.")
          |> Map.put(:consult, nil)
          |> set_state(:listening)
      end
    end
  end

  def event({:consult_confirm_progress, id}, %{consult: %{id: id, phase: :proposed}} = state),
    do: check_pending_target(state, id, :consult_confirm_progress)

  def event({:consult_unknown_progress, id}, %{consult: %{id: id, phase: :unknown}} = state),
    do: check_pending_target(state, id, :consult_unknown_progress)

  def event({:consult_timeout, ref}, %{consult: %{id: ref, phase: :waiting}} = state) do
    Runtime.consult_context(state, "No answer yet.")
  end

  def event({:consult_progress, ref}, %{consult: %{id: ref, phase: :waiting}} = state) do
    if target_ended?(state) do
      state = Runtime.consult_context(state, "The agent has ended; the question is stale.")
      state |> transition(ref, :stale) |> Map.put(:consult, nil) |> set_state(:listening)
    else
      state =
        if DateTime.diff(state.clock.(), state.last_user_at) >= 60 do
          case Ports.call_port(state.config.briefing_source, :brief, [state.target], :brief) do
            {:ok, %VoiceConverse.Briefing{} = briefing} ->
              {text, _meta} = VoiceConverse.Briefing.render(briefing, budget: state.config.limits.briefing_token_budget)
              Runtime.consult_context(state, "Still waiting. " <> state.config.redactor.(text))

            _ ->
              state
          end
        else
          state
        end

      _ = state.schedule_after.(60_000, {:consult_progress, ref})
      state
    end
  end

  def event({:fork_error, ref, _reason}, %{consult: %{id: id, delivery_id: ref, phase: :fork_waiting}} = state),
    do: event({:consult_fork_timeout, id, ref}, state)

  def event({:receipt, ref, status}, %{consult: %{id: id, delivery_id: ref, phase: :waiting}} = state) do
    case status do
      :accepted ->
        transition(state, id, :sent)

      :delivered ->
        state |> transition(id, :sent) |> transition(id, :delivered)

      :unknown ->
        Runtime.consult_context(state, "Delivery is uncertain; the agent may still receive the question.")

      :failed ->
        state
        |> transition(id, :sent)
        |> transition(id, :failed)
        |> Runtime.consult_context("The question could not be delivered.")
        |> Map.put(:consult, nil)
        |> set_state(:listening)

      _ ->
        state
    end
  end

  def event(_message, state), do: state

  def note_session_end(%{consult: nil} = state), do: {:ok, state}

  def note_session_end(%{consult: %{id: id}} = state) do
    case TranscriptStore.append(state.store, %{
           type: "delivery",
           draft_id: id,
           status: "open_at_session_end",
           at: now(state)
         }) do
      :ok -> {:ok, state}
      {:error, _reason} -> {:error, state}
    end
  end

  def delivery_failed(state, draft, reason) do
    state = state |> transition(draft.draft_id, :failed) |> discarded(draft.draft_id)
    {:error, reason, state}
  rescue
    _error -> unknown_delivery(state, draft)
  catch
    _kind, _reason -> unknown_delivery(state, draft)
  end

  def discarded(%{consult: %{id: id}} = state, id), do: state |> Map.put(:consult, nil) |> set_state(:listening)
  def discarded(state, _id), do: state

  defp confirm?(%{config: %{ask_requires_confirm: :always}}), do: true
  defp confirm?(%{config: %{ask_requires_confirm: :never}}), do: false
  defp confirm?(state), do: not state.consult_confirmed?

  defp transition(state, id, status) do
    case Drafts.transition(state.drafts, id, status, at: now(state)) do
      {:ok, draft, drafts} ->
        case persist(state, draft) do
          :ok -> %{state | drafts: drafts}
          {:error, reason} -> raise "consult transcript write failed: #{inspect(reason)}"
        end

      _ ->
        state
    end
  end

  defp check_pending_target(state, id, event) do
    if target_ended?(state) do
      state
      |> transition(id, :stale)
      |> Runtime.consult_context("The agent has ended; the question is stale.")
      |> Map.put(:consult, nil)
      |> set_state(:listening)
    else
      _ = state.schedule_after.(60_000, {event, id})
      state
    end
  end

  defp persist_answer!(state, id, text, source) do
    case TranscriptStore.append(state.store, %{
           type: "delivery",
           draft_id: id,
           status: "answered",
           text: text,
           source: source,
           at: now(state)
         }) do
      :ok -> :ok
      {:error, reason} -> raise "consult transcript write failed: #{inspect(reason)}"
    end
  end

  defp persist(state, draft) do
    record = Drafts.record(draft)

    case TranscriptStore.append(state.store, record) do
      :ok ->
        state.event_broadcast.(state.subscribers, state.id, {:draft, record})
        :ok

      error ->
        error
    end
  end

  defp result(text, error \\ false), do: %{text: text, is_error: error, end?: false}

  defp target_ended?(state),
    do: Ports.call_port(state.config.briefing_source, :alive?, [state.target], :brief) == false

  defp async_listener?(state, channel) do
    case Ports.call_port(channel, :capabilities, [state.target], :ask) do
      %{listener_mode: :async} -> true
      _ -> false
    end
  end

  defp set_state(%{provider_ref: nil} = state, :listening), do: set_state(state, :reconnecting)

  defp set_state(state, name) do
    state.event_broadcast.(state.subscribers, state.id, {:state, name})
    Enum.each(Map.keys(state.subscribers), &send(&1, {:voice_conversation_state, state.id, name}))
    %{state | state: name}
  end

  defp now(state), do: DateTime.to_iso8601(state.clock.())
end
