defmodule AiurWeb.OperatorControlCenter.DecisionAnswerCommands do
  @moduledoc false
  import Phoenix.Component, only: [assign: 3]
  alias Aiur.Commands.Answering
  alias AiurWeb.EndpointConfig
  alias AiurWeb.OperatorControlCenter.{DecisionAction, DecisionCommands, DecisionOutcomes}
  alias Phoenix.LiveView.Socket

  @type reload_fun :: (Socket.t() -> Socket.t())

  @spec change(Socket.t(), String.t(), map()) :: Socket.t()
  def change(socket, id, form) do
    case loaded(socket, id) do
      nil -> socket
      decision -> put_form(socket, id, normalize_form(form), decision)
    end
  end

  @spec record_answer(Socket.t(), String.t(), map(), reload_fun()) :: Socket.t()
  def record_answer(socket, id, form, reload), do: submit(socket, id, form, reload, :answer)

  @spec replace(Socket.t(), String.t(), map(), reload_fun()) :: Socket.t()
  def replace(socket, id, form, reload) do
    if get_in(socket.assigns.decision_actions, [id, :replacing?]),
      do: submit(socket, id, form, reload, :supersede),
      else: socket
  end

  @spec begin_replace(Socket.t(), String.t()) :: Socket.t()
  def begin_replace(socket, id) do
    case loaded(socket, id) do
      %{conflict_summary: %{actor_kind: :executor, replaceable: true}} = decision ->
        put_state(socket, id, %{replacing?: true, form: %{"choice" => "custom"}, decision_identity: identity(decision)})

      _unavailable ->
        socket
    end
  end

  defp submit(socket, id, form, reload, operation) do
    case loaded(socket, id) do
      nil -> put_result(reload.(socket), id, %{status: :error, reason: :not_loaded})
      decision -> submit_loaded(socket, decision, form, reload, operation)
    end
  end

  defp submit_loaded(socket, decision, form, reload, operation) do
    id = decision.decision_id
    form = normalize_form(form)
    socket = put_form(socket, id, form, decision)

    case answer_content(form) do
      {:ok, answer} ->
        {key, socket} = ensure_action_key(socket, id)
        payload = Map.merge(answer, %{"idempotency_key" => key, "expected_version" => decision.version})
        payload = maybe_put_rationale(payload, form["rationale"])
        payload = replacement_rationale(payload, operation)
        result = apply(Answering, operation, [id, payload, options()])
        reloaded = retain_draft(reload.(socket), socket, id, result)
        put_result(reloaded, id, result)

      {:error, message} ->
        update_state(socket, id, &Map.put(&1, :error, message))
    end
  end

  defp replacement_rationale(payload, :supersede), do: Map.put_new(payload, "rationale", "Replaced the Executor's undelivered answer from the dashboard.")
  defp replacement_rationale(payload, :answer), do: payload

  defp retain_draft(reloaded, previous, id, %{status: :stale}) do
    update_state(reloaded, id, &Map.put(&1, :form, get_in(previous.assigns.decision_actions, [id, :form]) || %{}))
  end

  defp retain_draft(reloaded, _previous, _id, _result), do: reloaded
  defp normalize_form(form) when is_map(form), do: Map.take(form, ["choice", "custom_response", "rationale"])
  defp normalize_form(_form), do: %{}

  defp options do
    [actor: DecisionCommands.actor(), actor_source: :dashboard_session, client: %{surface: :dashboard}, store: EndpointConfig.get(:decision_store) || Aiur.Commands.default_store()]
  end

  # Delivery-failure alerts are not operator Commands, even with an open status.
  # Settled Commands remain loadable so Answering can arbitrate replacement races.
  defp loaded(%{assigns: %{selected_decision: %{decision_id: id, open?: false, decision_status: status}}}, id)
       when status in [:open, :deferred, :expired],
       do: nil

  defp loaded(%{assigns: %{selected_decision: %{decision_id: id} = decision}}, id), do: decision
  defp loaded(%{assigns: %{selected_decision_id: id}}, id), do: nil

  defp loaded(socket, id) do
    socket.assigns |> get_in([:decision_page, :decisions]) |> List.wrap() |> Enum.find(&(&1.decision_id == id and DecisionAction.answerable?(&1)))
  end

  defp put_result(socket, id, outcome) do
    outcome = enrich_outcome(outcome, loaded(socket, id))
    {level, text, _actions} = DecisionOutcomes.outcome_notice(outcome)
    key = if level == :success, do: :notice, else: :error

    update_state(socket, id, fn state ->
      state = state |> Map.drop([:notice, :error]) |> Map.merge(%{key => text, outcome: outcome})
      state = if level == :success, do: state |> Map.put(:form, %{}) |> Map.delete(:replacing?), else: state

      case loaded(socket, id) do
        nil -> state
        decision -> Map.put(state, :decision_identity, identity(decision))
      end
    end)
  end

  defp enrich_outcome(%{status: :too_late} = outcome, decision) when is_map(decision),
    do: Map.put(outcome, :delivered_at, DecisionOutcomes.delivered_at(decision))

  defp enrich_outcome(outcome, _decision), do: outcome

  defp answer_content(%{"choice" => "option:" <> id}) when id != "", do: {:ok, %{"option_id" => id}}

  defp answer_content(%{"choice" => "custom", "custom_response" => response}) when is_binary(response) do
    case String.trim(response) do
      "" -> {:error, "Enter a custom response before recording this answer."}
      response -> {:ok, %{"custom_response" => response}}
    end
  end

  defp answer_content(%{"choice" => "custom"}), do: {:error, "Enter a custom response before recording this answer."}
  defp answer_content(_form), do: {:error, "Choose an option or a custom response."}

  defp maybe_put_rationale(payload, rationale) when is_binary(rationale) do
    case String.trim(rationale) do
      "" -> payload
      rationale -> Map.put(payload, "rationale", rationale)
    end
  end

  defp maybe_put_rationale(payload, _rationale), do: payload

  defp ensure_action_key(socket, id) do
    state = Map.get(socket.assigns.decision_actions, id, %{})
    key = state[:idempotency_key] || "ui_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    {key, put_state(socket, id, Map.put(state, :idempotency_key, key))}
  end

  defp put_form(socket, id, form, decision) do
    update_state(socket, id, fn state ->
      state |> Map.put(:decision_identity, identity(decision)) |> Map.put(:form, Map.take(form, ["choice", "custom_response", "rationale"])) |> Map.drop([:error, :notice, :outcome])
    end)
  end

  defp update_state(socket, id, fun), do: put_state(socket, id, fun.(Map.get(socket.assigns.decision_actions, id, %{})))
  defp put_state(socket, id, state), do: assign(socket, :decision_actions, Map.put(socket.assigns.decision_actions, id, state))
  defp identity(decision), do: {decision.version, decision.active_action_id}
end
