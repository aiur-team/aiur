defmodule Aiur.Commands.Answering do
  @moduledoc "Human-surface answer submission, attribution, and replacement precedence."

  alias Aiur.Commands.Answering.{Outcome, QuestionAnswers}
  alias Aiur.{Decision, DecisionAnswer, DecisionStore}

  @type surface :: :dashboard | :streamdeck | :cli | :api | :phone | :watch | :conversation
  @type outcome :: Outcome.t()

  @doc "Submit an answer with trusted actor, client, and required actor_source options."
  @spec answer(String.t(), map(), keyword()) :: outcome()
  def answer(decision_id, payload, opts), do: submit(:answer, decision_id, payload, opts)

  @doc "Replace an undelivered answer, or answer a Command with nothing to replace."
  @spec supersede(String.t(), map(), keyword()) :: outcome()
  def supersede(decision_id, payload, opts), do: submit(:supersede, decision_id, payload, opts)

  @doc "Normalize a store result; opts carry the decision_id, actor, and store context."
  @spec outcome(term(), keyword()) :: outcome()
  def outcome(result, opts), do: Outcome.normalize(result, opts)

  @doc "Render validated question answers in question order for v1 readers."
  @spec render_question_answers(list(), map()) :: String.t()
  def render_question_answers(questions, answers), do: QuestionAnswers.render(questions, answers)

  @doc "Decode a multi-question envelope or project a legacy answer onto the first question."
  @spec decode_question_answers(list(), map()) :: {:ok, map()} | {:error, term()}
  def decode_question_answers(questions, answer), do: QuestionAnswers.decode(questions, answer)

  defp submit(operation, decision_id, payload, opts) do
    unless Keyword.has_key?(opts, :actor_source), do: raise(ArgumentError, "actor_source is required")

    case facade_actor(operation, opts) do
      {:ok, actor} -> submit_as_actor(operation, decision_id, payload, Keyword.put(opts, :actor, actor))
      _invalid -> %{status: :not_allowed, reason: :invalid_actor}
    end
  catch
    :exit, _reason -> %{status: :error, reason: :store_unavailable}
  end

  defp submit_as_actor(operation, decision_id, payload, opts) do
    opts = Keyword.put(opts, :decision_id, decision_id)
    store = Keyword.get(opts, :store, DecisionStore)

    case prepare_payload(decision_id, payload, opts, store) do
      {:ok, payload, opts} ->
        result = call_store(operation, decision_id, payload, opts, store)
        result = retry_cross_device(result, operation, decision_id, payload, opts, store)
        outcome(result, opts)

      {:error, reason} ->
        outcome({:error, reason}, opts)
    end
  end

  defp facade_actor(operation, opts) do
    client = Keyword.get(opts, :client, %{})

    with {:ok, actor} <- DecisionAnswer.normalize_actor(Keyword.get(opts, :actor)),
         true <- direct_human?(actor) or (operation == :answer and client[:surface] == :cli and actor.kind == :executor) do
      attribute_client(actor, client)
    end
  end

  defp attribute_client(actor, %{surface: surface, device_id: id}) when surface in [:phone, :watch] and is_binary(id) and id != "",
    do: {:ok, %{actor | id: "device:" <> id}}

  defp attribute_client(_actor, %{surface: surface}) when surface in [:phone, :watch], do: {:error, :invalid_client}
  defp attribute_client(actor, %{surface: surface}) when surface in [:dashboard, :streamdeck], do: {:ok, %{actor | id: Atom.to_string(surface)}}
  defp attribute_client(actor, _client), do: {:ok, actor}

  defp prepare_payload(decision_id, payload, opts, store) do
    with {:ok, decision} <- DecisionStore.get(decision_id, store) do
      questions = Map.get(decision, :questions, [])
      answers = Map.get(payload, :question_answers, Map.get(payload, "question_answers"))

      encoded =
        cond do
          not is_nil(answers) -> QuestionAnswers.encode(payload, questions, answers)
          length(questions) > 1 -> {:error, {:question_answers, :incomplete}}
          true -> {:ok, payload}
        end

      with {:ok, payload} <- encoded do
        {:ok, payload, replay_actor(decision, payload, opts)}
      end
    end
  end

  # A retry from another human device retains the first device's provenance.
  # The store still compares the complete payload hash and rejects changed content.
  defp replay_actor(decision, payload, opts) do
    key = Map.get(payload, :idempotency_key, Map.get(payload, "idempotency_key"))
    accepted = Decision.active_answer(decision)

    if direct_human?(opts[:actor]) and is_binary(key) and not is_nil(accepted) and accepted.actor.kind == opts[:actor].kind and
         accepted.action_id == DecisionAnswer.action_id(decision.decision_id, String.trim(key)) do
      Keyword.put(opts, :actor, accepted.actor)
    else
      opts
    end
  end

  defp retry_cross_device({:error, {:conflict, {:idempotency_conflict, _action}}} = result, operation, id, payload, opts, store) do
    # Two devices may both read the unanswered version before the first write.
    with {:ok, decision} <- DecisionStore.get(id, store),
         replay_opts <- replay_actor(decision, payload, opts),
         false <- replay_opts[:actor].id == opts[:actor].id do
      call_store(operation, id, payload, replay_opts, store)
    else
      _unchanged -> result
    end
  end

  defp retry_cross_device(result, _operation, _id, _payload, _opts, _store), do: result

  defp call_store(:answer, id, payload, opts, store), do: DecisionStore.answer(id, payload, opts, store)

  defp call_store(:supersede, id, payload, opts, store) do
    case DecisionStore.supersede(id, payload, opts, store) do
      {:error, {:not_decided, _status}} -> DecisionStore.answer(id, payload, opts, store)
      result -> result
    end
  end

  @spec direct_human?(DecisionAnswer.actor()) :: boolean()
  def direct_human?(%{kind: kind}), do: kind == :operator

  @spec human_attributed?(DecisionAnswer.actor()) :: boolean()
  def human_attributed?(%{kind: kind}), do: kind in [:operator, :operator_relayed]

  @spec precedence(DecisionAnswer.actor()) :: 1 | 2 | 3
  def precedence(%{kind: :operator}), do: 3
  def precedence(%{kind: :operator_relayed}), do: 2
  def precedence(%{kind: kind}) when kind in [:executor, :supervisor, :agent, :system], do: 1

  @spec require_actor_may_replace(DecisionAnswer.actor(), map()) :: :ok | {:error, {:conflict, {:human_answer | :direct_operator_answer, String.t()}}}
  def require_actor_may_replace(caller, %{actor: winner, action_id: action_id}) do
    cond do
      precedence(caller) >= precedence(winner) -> :ok
      winner.kind == :operator and caller.kind == :operator_relayed -> {:error, {:conflict, {:direct_operator_answer, action_id}}}
      true -> {:error, {:conflict, {:human_answer, action_id}}}
    end
  end
end
