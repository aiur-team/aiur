defmodule AiurWeb.OperatorControlCenter.DecisionCommands do
  @moduledoc """
  Coordinates writable decision commands while keeping canonical state in the
  decision store and ephemeral form state in the LiveView socket.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Aiur.DecisionStore
  alias AiurWeb.{ControlCenterPresenter, Endpoint}
  alias Phoenix.LiveView.Socket

  @type reload_fun :: (Socket.t() -> Socket.t())

  @spec change(Socket.t(), String.t(), map()) :: Socket.t()
  def change(socket, decision_id, form) do
    case selected_open_decision(socket, decision_id) do
      {:ok, _decision} -> put_form(socket, decision_id, form)
      :error -> socket
    end
  end

  @spec record_answer(Socket.t(), String.t(), map(), reload_fun()) :: Socket.t()
  def record_answer(socket, decision_id, form, reload_fun) when is_function(reload_fun, 1) do
    form = normalize_form(form)
    socket = put_form(socket, decision_id, form)

    case selected_open_decision(socket, decision_id) do
      {:ok, decision} -> submit_answer(socket, decision, form, reload_fun)
      :error -> put_error(reload_fun.(socket), decision_id, "This decision is no longer open.")
    end
  end

  @spec reject_incomplete(Socket.t()) :: Socket.t()
  def reject_incomplete(socket) do
    put_error(
      socket,
      socket.assigns.selected_decision_id,
      "The submitted answer was incomplete. Try again."
    )
  end

  @spec retry_delivery(Socket.t(), String.t(), String.t(), reload_fun()) :: Socket.t()
  def retry_delivery(socket, decision_id, action_id, reload_fun) when is_function(reload_fun, 1) do
    result = safe_retry_dispatch(decision_id, action_id)
    socket = reload_fun.(socket)

    case result do
      {:ok, status} -> put_notice(socket, decision_id, retry_notice(status))
      {:error, reason} -> put_error(socket, decision_id, command_error(reason))
    end
  end

  defp submit_answer(socket, decision, form, reload_fun) do
    with :ok <- require_confirmation(decision, form),
         {:ok, answer} <- answer_content(form) do
      {idempotency_key, socket} = ensure_action_key(socket, decision.decision_id)

      payload =
        answer
        |> Map.put("idempotency_key", idempotency_key)
        |> Map.put("expected_version", decision.version)
        |> maybe_put_rationale(Map.get(form, "rationale"))

      result = safe_answer(decision.decision_id, payload)
      socket = reload_fun.(socket)

      case result do
        {:ok, accepted} -> put_notice(socket, decision.decision_id, answer_notice(accepted))
        {:error, reason} -> put_error(socket, decision.decision_id, command_error(reason))
      end
    else
      {:error, message} -> put_error(socket, decision.decision_id, message)
    end
  end

  defp selected_open_decision(socket, decision_id) do
    case ControlCenterPresenter.find_decision(socket.assigns.payload, decision_id) do
      {:ok, %{decision_status: :open} = decision} -> {:ok, decision}
      _result -> :error
    end
  end

  defp normalize_form(form) when is_map(form) do
    Map.take(form, ["choice", "custom_response", "rationale", "confirmed"])
  end

  defp normalize_form(_form), do: %{}

  defp answer_content(%{"choice" => "option:" <> option_id}) when option_id != "" do
    {:ok, %{"option_id" => option_id}}
  end

  defp answer_content(%{"choice" => "custom", "custom_response" => response}) when is_binary(response) do
    case String.trim(response) do
      "" -> {:error, "Enter a custom response before recording this answer."}
      response -> {:ok, %{"custom_response" => response}}
    end
  end

  defp answer_content(%{"choice" => "custom"}),
    do: {:error, "Enter a custom response before recording this answer."}

  defp answer_content(_form), do: {:error, "Choose an option or a custom response."}

  defp require_confirmation(decision, form) do
    if confirmation_required?(decision) and Map.get(form, "confirmed") != "true" do
      {:error, "Confirm that you understand this irreversible or destructive action."}
    else
      :ok
    end
  end

  defp confirmation_required?(decision) do
    Map.get(decision, :reversibility) == :irreversible or
      Map.get(decision, :kind) == "destructive_op"
  end

  defp maybe_put_rationale(payload, rationale) when is_binary(rationale) do
    case String.trim(rationale) do
      "" -> payload
      rationale -> Map.put(payload, "rationale", rationale)
    end
  end

  defp maybe_put_rationale(payload, _rationale), do: payload

  defp safe_answer(decision_id, payload) do
    DecisionStore.answer(decision_id, payload, [actor: dashboard_actor()], decision_store())
  catch
    :exit, _reason -> {:error, :store_unavailable}
  end

  defp safe_retry_dispatch(decision_id, action_id) do
    DecisionStore.retry_dispatch(decision_id, action_id, decision_store())
  catch
    :exit, _reason -> {:error, :store_unavailable}
  end

  defp dashboard_actor, do: %{kind: :operator, id: dashboard_operator_id()}

  defp dashboard_operator_id do
    case System.get_env("AIUR_DASHBOARD_USERNAME") do
      username when is_binary(username) ->
        username |> String.trim() |> String.slice(0, 200) |> present_or("dashboard")

      _username ->
        "dashboard"
    end
  end

  defp present_or("", fallback), do: fallback
  defp present_or(value, _fallback), do: value

  defp ensure_action_key(socket, decision_id) do
    state = Map.get(socket.assigns.decision_actions, decision_id, %{})

    case Map.get(state, :idempotency_key) do
      key when is_binary(key) ->
        {key, socket}

      _key ->
        key = "ui_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
        {key, put_state(socket, decision_id, Map.put(state, :idempotency_key, key))}
    end
  end

  defp put_form(socket, decision_id, form) do
    update_state(socket, decision_id, fn state ->
      state
      |> Map.put(:form, normalize_form(form))
      |> Map.delete(:error)
      |> Map.delete(:notice)
    end)
  end

  defp put_error(socket, decision_id, message) do
    update_state(socket, decision_id, &(&1 |> Map.put(:error, message) |> Map.delete(:notice)))
  end

  defp put_notice(socket, decision_id, message) do
    update_state(socket, decision_id, fn state ->
      state |> Map.put(:notice, message) |> Map.delete(:error) |> Map.put(:form, %{})
    end)
  end

  defp update_state(socket, decision_id, fun) do
    state = socket.assigns.decision_actions |> Map.get(decision_id, %{}) |> fun.()
    put_state(socket, decision_id, state)
  end

  defp put_state(socket, decision_id, state) do
    assign(socket, :decision_actions, Map.put(socket.assigns.decision_actions, decision_id, state))
  end

  defp answer_notice(%{status: :duplicate}),
    do: "This durable answer was already recorded. Canonical state was refreshed."

  defp answer_notice(%{dispatch_status: :queued}), do: "Answer recorded and queued for delivery."

  defp answer_notice(%{dispatch_status: :delivered}),
    do: "Answer recorded and delivered; acknowledgement is pending."

  defp answer_notice(%{dispatch_status: :consumed}),
    do: "Answer recorded and consumed by the target queue."

  defp answer_notice(_accepted), do: "Answer recorded. Durable dispatch is pending."

  defp retry_notice(:scheduled), do: "A durable delivery retry was scheduled."
  defp retry_notice(:already_dispatching), do: "A delivery attempt is already in progress."

  defp command_error({:conflict, {:stale_version, _expected, current}}),
    do: "This decision changed to version #{current}. Review the refreshed state before answering."

  defp command_error({:conflict, {:already_decided, _action_id}}),
    do: "Another durable answer already won. Canonical state was refreshed."

  defp command_error({:conflict, {:idempotency_conflict, _action_id}}),
    do: "This submission token was already used with different content. Review the refreshed answer."

  defp command_error({:conflict, :resolved}), do: "This decision is already resolved."
  defp command_error({:answer_invalid, {:option_id, :unknown}}), do: "That option is no longer available."

  defp command_error({:answer_invalid, {_field, :too_long}}),
    do: "The response exceeds the allowed length."

  defp command_error({:answer_invalid, {_field, :unsafe_characters}}),
    do: "The response contains unsupported control characters."

  defp command_error({:store_unavailable, _reason}),
    do: "Decision storage is read-only or unavailable."

  defp command_error(:store_unavailable), do: "Decision storage is currently unavailable."
  defp command_error(:not_found), do: "This decision no longer exists."

  defp command_error(:action_mismatch),
    do: "The failed action changed. Review the refreshed state before retrying."

  defp command_error(:dispatch_not_failed),
    do: "Delivery is no longer failed, so no retry was scheduled."

  defp command_error(:answer_missing), do: "No durable answer is available to retry."
  defp command_error(_reason), do: "The command was rejected. Canonical state was refreshed."

  defp decision_store, do: Endpoint.config(:decision_store) || DecisionStore
end
