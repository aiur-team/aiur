defmodule Aiur.Orchestrator.OperatorMessages.DeliveryPolicy do
  @moduledoc """
  Normalizes message delivery requests and decides when queued work wakes a running agent.
  """

  alias Aiur.Opencode.ActiveTurns
  alias Aiur.Orchestrator.{CommentWake, EventTopics, PauseResume, State}

  @spec normalize_delivery_request(term(), term(), map()) ::
          {:ok, keyword()} | {:error, atom()}
  # `:auto` lets the caller defer to the backend: the persistent REPL takes
  # Executor messages immediately mid-turn; everything else holds at a safe
  # checkpoint (native codex/headless-claude turn UX).
  def normalize_delivery_request(:auto, _fallback, %{immediate_delivery: true}) do
    {:ok, [delivery_policy: :immediate]}
  end

  def normalize_delivery_request(:auto, _fallback, _capabilities) do
    {:ok, [delivery_policy: :checkpoint]}
  end

  def normalize_delivery_request(:immediate, _fallback, %{immediate_delivery: true}) do
    {:ok, [delivery_policy: :immediate]}
  end

  def normalize_delivery_request(:immediate, _fallback, _capabilities) do
    {:error, :immediate_not_supported}
  end

  def normalize_delivery_request(:checkpoint, _fallback, _capabilities) do
    {:ok, [delivery_policy: :checkpoint]}
  end

  def normalize_delivery_request(:interrupt, fallback, %{can_interrupt: true}) do
    {:ok, [delivery_policy: :interrupt, fallback: fallback]}
  end

  def normalize_delivery_request(:interrupt, :queue_next, _capabilities) do
    {:ok, [delivery_policy: :checkpoint, fallback: :queue_next]}
  end

  def normalize_delivery_request(:interrupt, _fallback, _capabilities) do
    {:error, :interrupt_not_supported}
  end

  def normalize_delivery_request(_other, _fallback, _capabilities) do
    {:error, :invalid_message}
  end

  @spec notify_running_queue_update(State.t(), map(), term()) :: :ok
  def notify_running_queue_update(%State{} = state, %{pid: pid} = running_entry, item) when is_pid(pid) do
    if Process.alive?(pid) do
      send(
        pid,
        {:agent_queue_updated, item.target_issue_identifier, item.id, deliver_now?(state, running_entry, item)}
      )
    end

    :ok
  end

  def notify_running_queue_update(_state, _running_entry, _item), do: :ok

  @spec event_digest_delivery_opts(map() | nil, term()) :: keyword()
  def event_digest_delivery_opts(running_entry, event_or_events),
    do: event_digest_delivery_opts(running_entry, event_or_events, false)

  # A blocker-critical digest must reach the running agent even while a parent
  # turn is live. Since the safe-checkpoint second-`turn/start` path is now
  # locked out, request `interrupt_requested: true` so the acknowledged
  # `turn/interrupt` steering primitive (single writer) carries the urgency.
  @spec event_digest_delivery_opts(map() | nil, term(), boolean()) :: keyword()
  def event_digest_delivery_opts(running_entry, event_or_events, blocker_critical?) do
    if queue_wake_required?(running_entry) or
         trusted_comment_wake_required?(running_entry, event_or_events) or
         blocker_interrupt_required?(running_entry, blocker_critical?) do
      [source: :system, priority: :now, interrupt_requested: true]
    else
      [source: :system]
    end
  end

  defp blocker_interrupt_required?(running_entry, true),
    do: State.active_running_entry?(running_entry)

  defp blocker_interrupt_required?(_running_entry, _blocker_critical?), do: false

  @doc false
  @spec comment_event_topic?(map()) :: boolean()
  def comment_event_topic?(event) when is_map(event) do
    topic = Map.get(event, :topic) || Map.get(event, "topic")

    if is_binary(topic) do
      case EventTopics.classify_event_topic(topic) do
        {:pr_review_comment, _identifier} -> true
        {:issue_commented, _identifier} -> true
        _ -> false
      end
    else
      false
    end
  end

  def comment_event_topic?(_event), do: false

  # The correlated resume is the sole wake for a paused (or pausing) worker.
  # An interrupt notification here can deliver an answer before the pause,
  # or start a turn before resume has released containment. "Pausing" means
  # the entry's pause request is still the current pending control; a
  # `pending_pause_reason` left by an expired or rejected request does not
  # count (#2730).
  # ...except an `:agent_pause_request`, which is a *cooperative* self-pause:
  # the agent stopped because the input it named has not arrived yet ("pause
  # until human review produces feedback"). Its correlated wake is that input,
  # not an operator resume — no operator resume is coming, because from the
  # operator's side the ticket is simply in rework. Refusing to deliver here
  # made the pause outlive the very condition it named: the review landed, the
  # digest was queued with `deliver_now?: false`, `claim_after_queue_update/3`
  # ignored it, and only a human `aiur resume` could lift the pause. Deliver
  # it, so the claim flips the entry to `:working` and
  # `PauseResume.clear_agent_pause_on_work/2` drops the pause reason. A pending
  # pause request still wins — the pause has not settled yet, so the #2730
  # ordering hazard above is unchanged.
  defp deliver_now?(state, %{control: %{status: :paused}} = running_entry, item) do
    if input_waiting_self_pause?(running_entry) and
         is_nil(PauseResume.current_pending_pause_reason(state, running_entry)) do
      wake_now?(running_entry, item)
    else
      false
    end
  end

  defp deliver_now?(state, running_entry, item) do
    if PauseResume.current_pending_pause_reason(state, running_entry),
      do: false,
      else: wake_now?(running_entry, item)
  end

  defp wake_now?(running_entry, item) do
    queue_wake_required?(running_entry) or
      item.delivery[:interrupt_requested] == true or
      item.delivery[:immediate] == true
  end

  # A self-paused agent waiting on review feedback is included here so the
  # digest carries `interrupt_requested: true` and can satisfy `wake_now?/2` —
  # `queue_wake_required?/1` only recognizes sleeping and active entries, so
  # without this the paused entry would be woken by nothing.
  defp trusted_comment_wake_required?(running_entry, event_or_events),
    do:
      (State.active_running_entry?(running_entry) or input_waiting_self_pause?(running_entry)) and
        trusted_comment_event_digest?(event_or_events)

  # Only `:agent_pause_request` — the agent's own "I am waiting for input"
  # pause. An operator pause, a global pause, a budget hold, a blocker pause
  # and pause containment all keep the "correlated resume is the sole wake"
  # rule: their clearing condition is not a review comment. `:input_required`
  # is excluded too — it names an outstanding operator *decision*, which a
  # review comment does not answer.
  defp input_waiting_self_pause?(running_entry) when is_map(running_entry),
    do: Map.get(running_entry, :paused_reason) == :agent_pause_request

  defp input_waiting_self_pause?(_running_entry), do: false

  @doc false
  @spec trusted_comment_event_digest?(term()) :: boolean()
  def trusted_comment_event_digest?(events) when is_list(events),
    do: Enum.any?(events, &trusted_comment_event_digest?/1)

  def trusted_comment_event_digest?(event) when is_map(event) do
    comment_event_topic?(event) and CommentWake.trusted_comment_event?(event) and
      not CommentWake.benign_review_pass_comment?(event)
  end

  def trusted_comment_event_digest?(_event), do: false

  defp queue_wake_required?(running_entry) do
    State.sleeping_running_entry?(running_entry) or
      (State.active_running_entry?(running_entry) and no_active_turn?(running_entry))
  end

  defp no_active_turn?(%{identifier: identifier}) when is_binary(identifier),
    do: ActiveTurns.active_turn_ids(identifier) == []

  defp no_active_turn?(_running_entry), do: false
end
