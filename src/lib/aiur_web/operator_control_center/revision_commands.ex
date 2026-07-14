defmodule AiurWeb.OperatorControlCenter.RevisionCommands do
  @moduledoc """
  Coordinates OCC8 revision and parent follow-up commands for the dashboard.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Aiur.DecisionStore
  alias AiurWeb.ControlCenterPresenter
  alias AiurWeb.Endpoint
  alias AiurWeb.OperatorControlCenter.DecisionCommands
  alias Phoenix.LiveView.Socket

  @type reload_fun :: (Socket.t() -> Socket.t())

  @spec change(Socket.t(), String.t(), map()) :: Socket.t()
  def change(socket, decision_id, form) do
    case answered_decision(socket, decision_id) do
      {:ok, _decision} -> put_revision_form(socket, decision_id, form)
      :error -> socket
    end
  end

  @spec revise(Socket.t(), String.t(), map(), reload_fun()) :: Socket.t()
  def revise(socket, decision_id, form, reload_fun) when is_function(reload_fun, 1) do
    form = normalize_revision_form(form)
    socket = put_revision_form(socket, decision_id, form)

    case answered_decision(socket, decision_id) do
      {:ok, decision} -> submit_revision(socket, decision, form, reload_fun)
      :error -> put_revision_error(reload_fun.(socket), decision_id, "This decision no longer has an active answer.")
    end
  end

  @spec reject_incomplete(Socket.t()) :: Socket.t()
  def reject_incomplete(socket) do
    put_revision_error(
      socket,
      socket.assigns.selected_decision_id,
      "The submitted revision was incomplete. Try again."
    )
  end

  @spec handle_follow_up(Socket.t(), String.t(), String.t(), map(), reload_fun()) :: Socket.t()
  def handle_follow_up(socket, decision_id, action_id, form, reload_fun)
      when is_function(reload_fun, 1) do
    detail = follow_up_detail(form)
    socket = put_follow_up_detail(socket, decision_id, detail)

    if detail == "" do
      put_follow_up_error(socket, decision_id, "Record how the follow-up was handled before closing it.")
    else
      result = safe_handle_follow_up(decision_id, action_id, detail)
      socket = reload_fun.(socket)

      case result do
        {:ok, %{status: status}} -> put_follow_up_notice(socket, decision_id, follow_up_notice(status))
        {:error, reason} -> put_follow_up_error(socket, decision_id, command_error(reason))
      end
    end
  end

  defp submit_revision(socket, decision, form, reload_fun) do
    with :ok <- require_confirmation(decision, form),
         {:ok, answer} <- answer_content(form),
         {:ok, reason} <- revision_reason(form) do
      {idempotency_key, socket} = ensure_revision_key(socket, decision.decision_id)

      payload =
        answer
        |> Map.put("idempotency_key", idempotency_key)
        |> Map.put("expected_version", decision.version)
        |> Map.put("expected_action_id", decision.active_action_id)
        |> Map.put("expected_revision_sequence", decision.revision_sequence)
        |> Map.put("rationale", reason)

      result = safe_revise(decision.decision_id, payload)
      socket = reload_fun.(socket)

      case result do
        {:ok, accepted} -> put_revision_notice(socket, decision.decision_id, revision_notice(accepted))
        {:error, reason} -> put_revision_error(socket, decision.decision_id, command_error(reason))
      end
    else
      {:error, message} -> put_revision_error(socket, decision.decision_id, message)
    end
  end

  defp answered_decision(
         %{assigns: %{selected_decision: %{decision_id: decision_id, answer: answer} = decision}},
         decision_id
       )
       when not is_nil(answer),
       do: {:ok, decision}

  defp answered_decision(socket, decision_id) do
    case ControlCenterPresenter.find_decision(socket.assigns.payload, decision_id) do
      {:ok, %{answer: answer} = decision} when not is_nil(answer) -> {:ok, decision}
      _result -> :error
    end
  end

  defp normalize_revision_form(form) when is_map(form) do
    Map.take(form, ["choice", "custom_response", "reason", "confirmed"])
  end

  defp normalize_revision_form(_form), do: %{}

  defp answer_content(%{"choice" => "option:" <> option_id}) when option_id != "" do
    {:ok, %{"option_id" => option_id}}
  end

  defp answer_content(%{"choice" => "custom", "custom_response" => response}) when is_binary(response) do
    case String.trim(response) do
      "" -> {:error, "Enter a revised custom response before recording this revision."}
      response -> {:ok, %{"custom_response" => response}}
    end
  end

  defp answer_content(%{"choice" => "custom"}),
    do: {:error, "Enter a revised custom response before recording this revision."}

  defp answer_content(_form), do: {:error, "Choose a revised option or custom response."}

  defp revision_reason(form) do
    case form |> Map.get("reason") |> trim_string() do
      "" -> {:error, "Explain why this decision is being revised."}
      reason -> {:ok, reason}
    end
  end

  defp require_confirmation(decision, form) do
    if confirmation_required?(decision) and Map.get(form, "confirmed") != "true" do
      {:error, "Confirm that you understand this revised direction may be irreversible or destructive."}
    else
      :ok
    end
  end

  defp confirmation_required?(decision) do
    Map.get(decision, :reversibility) == :irreversible or
      Map.get(decision, :kind) == "destructive_op"
  end

  defp safe_revise(decision_id, payload) do
    DecisionStore.revise(decision_id, payload, [actor: DecisionCommands.actor()], decision_store())
  catch
    :exit, _reason -> {:error, :store_unavailable}
  end

  defp safe_handle_follow_up(decision_id, action_id, detail) do
    DecisionStore.handle_revision_follow_up(
      decision_id,
      action_id,
      [actor: DecisionCommands.actor(), detail: detail],
      decision_store()
    )
  catch
    :exit, _reason -> {:error, :store_unavailable}
  end

  defp ensure_revision_key(socket, decision_id) do
    state = action_state(socket, decision_id)

    case Map.get(state, :revision_idempotency_key) do
      key when is_binary(key) ->
        {key, socket}

      _key ->
        key = "ui_rev_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
        {key, put_state(socket, decision_id, Map.put(state, :revision_idempotency_key, key))}
    end
  end

  defp put_revision_form(socket, decision_id, form) do
    update_state(socket, decision_id, fn state ->
      state
      |> Map.put(:revision_form, normalize_revision_form(form))
      |> Map.delete(:revision_error)
      |> Map.delete(:revision_notice)
    end)
  end

  defp put_revision_error(socket, decision_id, message) do
    update_state(socket, decision_id, &(&1 |> Map.put(:revision_error, message) |> Map.delete(:revision_notice)))
  end

  defp put_revision_notice(socket, decision_id, message) do
    update_state(socket, decision_id, fn state ->
      state
      |> Map.put(:revision_notice, message)
      |> Map.delete(:revision_error)
      |> Map.delete(:revision_form)
      |> Map.delete(:revision_idempotency_key)
    end)
  end

  defp put_follow_up_detail(socket, decision_id, detail) do
    update_state(socket, decision_id, &Map.put(&1, :follow_up_detail, detail))
  end

  defp put_follow_up_error(socket, decision_id, message) do
    update_state(socket, decision_id, &(&1 |> Map.put(:follow_up_error, message) |> Map.delete(:follow_up_notice)))
  end

  defp put_follow_up_notice(socket, decision_id, message) do
    update_state(socket, decision_id, fn state ->
      state
      |> Map.put(:follow_up_notice, message)
      |> Map.delete(:follow_up_error)
      |> Map.delete(:follow_up_detail)
    end)
  end

  defp update_state(socket, decision_id, fun) do
    state = socket |> action_state(decision_id) |> fun.()
    put_state(socket, decision_id, state)
  end

  defp action_state(socket, decision_id), do: Map.get(socket.assigns.decision_actions, decision_id, %{})

  defp put_state(socket, decision_id, state) do
    assign(socket, :decision_actions, Map.put(socket.assigns.decision_actions, decision_id, state))
  end

  defp revision_notice(%{status: :duplicate}),
    do: "This durable revision was already recorded. Canonical state was refreshed."

  defp revision_notice(%{revision_result: :dispatched}),
    do: "Revision recorded and corrective follow-up queued."

  defp revision_notice(%{revision_result: :no_longer_applicable}),
    do: "Revision recorded; the target is no longer active and Executor follow-up is required."

  defp revision_notice(_accepted), do: "Revision recorded; corrective follow-up is pending."

  defp follow_up_notice(:duplicate), do: "This revision follow-up was already handled."
  defp follow_up_notice(_status), do: "Revision follow-up handled and its reminder is resolving."

  defp command_error({:conflict, {:stale_action, _correlation}}),
    do: "The active action changed. Review the refreshed revision state before trying again."

  defp command_error({:conflict, {:stale_sequence, _correlation}}),
    do: "The revision sequence changed. Review the refreshed state before trying again."

  defp command_error({:conflict, {:stale_version, _expected, current}}),
    do: "This decision changed to version #{current}. Review the refreshed state before revising."

  defp command_error({:conflict, {:idempotency_conflict, _action_id}}),
    do: "This revision token was already used with different content. Refresh before trying again."

  defp command_error({:revision_invalid, {:answer_invalid, {:option_id, :unknown}}}),
    do: "That revision option is no longer available."

  defp command_error({:store_unavailable, _reason}), do: "Decision storage is read-only or unavailable."
  defp command_error(:store_unavailable), do: "Decision storage is currently unavailable."
  defp command_error(:follow_up_not_required), do: "This revision follow-up is no longer open."
  defp command_error(:not_found), do: "This decision no longer exists."
  defp command_error(_reason), do: "The revision command was rejected. Canonical state was refreshed."

  defp trim_string(value) when is_binary(value), do: String.trim(value)
  defp trim_string(_value), do: ""

  defp follow_up_detail(form) when is_map(form), do: form |> Map.get("detail") |> trim_string()
  defp follow_up_detail(_form), do: ""

  defp decision_store, do: Endpoint.config(:decision_store) || DecisionStore
end
