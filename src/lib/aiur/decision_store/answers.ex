defmodule Aiur.DecisionStore.Answers do
  @moduledoc false

  require Logger

  alias Aiur.Decision
  alias Aiur.DecisionAnswer
  alias Aiur.DecisionAuthority
  alias Aiur.DecisionStore.Dedup
  alias Aiur.DecisionStore.Dispatch
  alias Aiur.DecisionStore.Persistence
  alias Aiur.DecisionStore.Withdrawals

  @spec handle_answer(term(), term(), term(), term()) :: term()
  def handle_answer(decision_id, payload, opts, state) do
    with {:ok, decision} <- fetch_decision(state, decision_id),
         {:ok, actor} <- fetch_actor(opts) do
      accept_or_replay_answer(decision, payload, actor, opts, state)
    else
      {:error, reason} -> {:reply, {:error, reason}, Persistence.journal_failure_state(state, reason)}
    end
  end

  @doc false
  @spec consume_pending_for_session(String.t(), String.t(), [String.t()], term()) :: term()
  def consume_pending_for_session(ticket_identifier, session_id, action_ids, state) do
    action_ids = MapSet.new(action_ids)

    state.current
    |> Map.values()
    |> Enum.filter(&(&1.ticket.identifier == ticket_identifier and &1.pending_for_session? and MapSet.member?(action_ids, &1.active_action_id)))
    |> Enum.reduce(state, fn decision, acc ->
      case Persistence.build_and_persist_event(:session_started, decision, %{action_id: decision.active_action_id, session_id: session_id}, DateTime.utc_now(), acc) do
        {:ok, next_state, _updated} -> next_state
        {:error, reason} -> Persistence.journal_failure_state(acc, reason)
      end
    end)
  end

  @doc false
  @spec handle_ticket_comment_published(String.t(), String.t(), term()) :: term()
  def handle_ticket_comment_published(decision_id, action_id, state) do
    case Map.get(state.current, decision_id) do
      %Decision{answer: %{action_id: ^action_id}, ticket_comment_status: :pending} = decision ->
        data = %{action_id: action_id}

        case Persistence.build_and_persist_event(:answer_comment_published, decision, data, DateTime.utc_now(), state) do
          {:ok, next_state, _updated} -> next_state
          {:error, reason} -> Persistence.journal_failure_state(state, reason)
        end

      _already_published_or_replaced ->
        state
    end
  end

  defp accept_or_replay_answer(%Decision{answer: nil} = decision, payload, actor, opts, state) do
    case require_answerable(decision) do
      :ok -> accept_answer(decision, payload, actor, opts, state)
      {:error, reason} -> {:reply, {:error, reason}, Persistence.journal_failure_state(state, reason)}
    end
  end

  defp accept_or_replay_answer(%Decision{answer: %DecisionAnswer{}} = decision, payload, actor, opts, state) do
    replay_answer(decision, payload, actor, opts, state)
  end

  @spec fetch_decision(term(), term()) :: term()
  def fetch_decision(state, decision_id) do
    case Map.fetch(state.current, decision_id) do
      {:ok, decision} -> {:ok, decision}
      :error -> {:error, :not_found}
    end
  end

  @spec require_answerable(term()) :: term()
  # An expired unanswered blocking Command remains actionable: the agent may
  # still be waiting on its answer, so expiry must not remove that path.
  def require_answerable(%Decision{decision_status: :expired, blocking: true, answer: nil}), do: :ok

  def require_answerable(%Decision{decision_status: status}) when status in [:expired, :moot, :resolved],
    do: {:error, {:conflict, status}}

  def require_answerable(%Decision{}), do: :ok

  @spec fetch_actor(term()) :: term()
  def fetch_actor(opts) do
    case Keyword.fetch(opts, :actor) do
      {:ok, actor} when is_map(actor) -> {:ok, actor}
      _other -> {:error, {:answer_invalid, {:actor, :missing}}}
    end
  end

  defp accept_answer(decision, payload, actor, opts, state) do
    case normalize_answer(payload, decision, decision.version, decision.options, actor, opts) do
      {:ok, answer} -> persist_answer(decision, answer, state)
      {:error, reason} -> {:reply, {:error, answer_error(reason)}, state}
    end
  end

  defp replay_answer(decision, payload, actor, opts, state) do
    accepted = decision.answer
    addressed = request_version(state, decision.decision_id, accepted.decision_version) || decision

    case normalize_answer(payload, addressed, accepted.decision_version, addressed.options, actor, opts) do
      {:ok, replayed} -> evaluate_answer_replay(decision, accepted, replayed, state)
      {:error, reason} -> {:reply, {:error, answer_error(reason)}, state}
    end
  end

  @spec normalize_answer(term(), term(), term(), term(), term(), term()) :: term()
  def normalize_answer(payload, request, decision_version, options, actor, opts) do
    with {:ok, answer} <-
           DecisionAnswer.normalize(payload,
             decision_id: request.decision_id,
             decision_version: decision_version,
             options: options,
             actor: actor,
             supervisor_basis: Keyword.get(opts, :supervisor_basis),
             ticket_comment_pending?: true,
             now: Keyword.get(opts, :now, DateTime.utc_now())
           ),
         :ok <- validate_answer_policy_context(answer, request) do
      {:ok, answer}
    end
  end

  defp validate_answer_policy_context(
         %DecisionAnswer{
           actor: %{kind: :supervisor},
           supervisor_basis: %{policy_basis: policy_basis}
         },
         %Decision{} = request
       ) do
    request_kind = request.kind && String.downcase(String.trim(request.kind))

    if policy_basis.authority == request.authority and policy_basis.kind == request_kind and
         policy_basis.reversibility == request.reversibility do
      :ok
    else
      {:error, {:answer_invalid, {:supervisor_basis, :decision_mismatch}}}
    end
  end

  defp validate_answer_policy_context(%DecisionAnswer{actor: %{kind: :supervisor}}, %Decision{}),
    do: {:error, {:answer_invalid, {:supervisor_basis, :decision_mismatch}}}

  # The Executor may answer a Command directly, but "obvious" needs a floor the
  # code enforces rather than one the Executor's prompt is trusted to observe.
  # The Command's own author declares how consequential it is, so that
  # declaration is the gate: only an already-delegable authority and a fully
  # reversible outcome may be auto-answered. Everything else — human_required,
  # irreversible or partially reversible work, and any unrecognized or missing
  # value — is refused here so the Executor must escalate it to the operator
  # instead. This mirrors the supervisor basis check directly above: both bind
  # a non-operator answer to the Decision's own declared policy fields.
  defp validate_answer_policy_context(%DecisionAnswer{actor: %{kind: :executor}}, %Decision{} = request) do
    cond do
      not DecisionAuthority.executor_authority_answerable?(request) ->
        {:error, {:answer_invalid, {:executor_scope, {:authority, request.authority}}}}

      not DecisionAuthority.executor_reversibility_answerable?(request) ->
        {:error, {:answer_invalid, {:executor_scope, {:reversibility, request.reversibility}}}}

      true ->
        :ok
    end
  end

  defp validate_answer_policy_context(%DecisionAnswer{}, %Decision{}), do: :ok

  defp answer_error({:answer_invalid, {:stale_version, expected, current}}),
    do: {:conflict, {:stale_version, expected, current}}

  defp answer_error(reason), do: reason

  @spec request_version(term(), term(), term()) :: term()
  def request_version(state, decision_id, version) do
    state.history
    |> Map.get(decision_id, [])
    |> Enum.find(&(&1.version == version))
  end

  defp evaluate_answer_replay(decision, accepted, replayed, state) do
    cond do
      replayed.action_id == accepted.action_id and replayed.content_hash == accepted.content_hash ->
        next_state = Dispatch.maybe_schedule_after_answer(state, decision, false)
        schedule_ticket_comment(decision, state.answer_comment_publisher)

        {:reply,
         {:ok,
          %{
            status: :duplicate,
            decision: decision,
            action: accepted,
            dispatch_status: Withdrawals.dispatch_status(decision)
          }}, next_state}

      replayed.action_id == accepted.action_id ->
        {:reply, {:error, {:conflict, {:idempotency_conflict, accepted.action_id}}}, state}

      true ->
        {:reply, {:error, {:conflict, {:already_decided, accepted.action_id}}}, state}
    end
  end

  defp persist_answer(decision, answer, state) do
    case Persistence.build_and_persist_event(:answer_recorded, decision, answer, answer.accepted_at, state) do
      {:ok, next_state, updated} ->
        schedule_ticket_comment(updated, state.answer_comment_publisher)

        next_state =
          next_state
          |> Dispatch.maybe_schedule_after_answer(updated, false)
          |> Dedup.supersede_duplicates(updated)

        {:reply,
         {:ok,
          %{
            status: :accepted,
            decision: updated,
            action: answer,
            dispatch_status: :dispatch_pending
          }}, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, Persistence.journal_failure_state(state, reason)}
    end
  end

  @doc false
  @spec schedule_ticket_comment(Decision.t(), (Decision.t() -> term())) :: :ok
  def schedule_ticket_comment(decision, publisher) do
    start_ticket_comment_task(decision, publisher, self())
    :ok
  end

  defp start_ticket_comment_task(decision, publisher, store) do
    Task.Supervisor.start_child(Aiur.TaskSupervisor, fn ->
      case publish_ticket_comment(decision, publisher, [0, 1_000, 5_000, 30_000]) do
        :ok -> send(store, {:answer_comment_published, decision.decision_id, decision.answer.action_id})
        :error -> :ok
      end
    end)
  end

  defp publish_ticket_comment(decision, publisher, [0 | rest]) do
    publish_ticket_comment_attempt(decision, publisher, rest)
  end

  defp publish_ticket_comment(decision, publisher, [delay | rest]) when delay > 0 do
    Process.sleep(delay)
    publish_ticket_comment_attempt(decision, publisher, rest)
  end

  defp publish_ticket_comment(decision, _publisher, []) do
    Logger.error("aiur_decision_answer_comment phase=retries_exhausted decision_id=#{decision.decision_id}")
    :error
  end

  defp publish_ticket_comment_attempt(decision, publisher, rest) do
    case publisher.(decision) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("aiur_decision_answer_comment phase=publish_failed decision_id=#{decision.decision_id} reason_class=#{safe_failure_class(reason)}")
        publish_ticket_comment(decision, publisher, rest)

      other ->
        Logger.warning("aiur_decision_answer_comment phase=publish_failed decision_id=#{decision.decision_id} result_class=#{safe_failure_class(other)}")
        publish_ticket_comment(decision, publisher, rest)
    end
  end

  defp safe_failure_class(reason) when is_atom(reason), do: reason
  defp safe_failure_class({kind, _detail}) when is_atom(kind), do: kind
  defp safe_failure_class({kind, _class, _detail}) when is_atom(kind), do: kind
  defp safe_failure_class(_reason), do: :unknown
end
