defmodule Aiur.Codex.Approvals do
  @moduledoc """
  Codex approval request and tool-call servicing for app-server turn methods.
  """

  alias Aiur.AppServer.Messages
  alias Aiur.Codex.{Rpc, UserInputAnswers}

  # credo:disable-for-this-file Credo.Check.Refactor.FunctionArity

  @spec maybe_handle_approval_request(
          port(),
          String.t(),
          map(),
          String.t(),
          (map() -> term()),
          map(),
          (term(), term() -> term()),
          boolean(),
          boolean()
        ) :: :approved | :approval_required | :input_required | :unhandled
  def maybe_handle_approval_request(port, method, %{"id" => id} = payload, payload_string, on_message, metadata, _tool_executor, _auto_approve_requests, true) do
    deny_for_pause(port, method, id, payload, payload_string, on_message, metadata)
  end

  def maybe_handle_approval_request(port, method, payload, payload_string, on_message, metadata, tool_executor, auto_approve_requests, true) do
    # A latched pause only gates approval/tool requests, which carry a JSON-RPC
    # id. Id-less notifications (message/reasoning deltas, status) keep their
    # normal handling so a mid-turn pause does not crash the streaming loop.
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    maybe_handle_approval_request(port, method, payload, payload_string, on_message, metadata, tool_executor, auto_approve_requests, false)
  end

  def maybe_handle_approval_request(
        port,
        "item/commandExecution/requestApproval",
        %{"id" => id} = payload,
        payload_string,
        on_message,
        metadata,
        _tool_executor,
        auto_approve_requests,
        false
      ) do
    approve_or_require(port, id, "acceptForSession", payload, payload_string, on_message, metadata, auto_approve_requests)
  end

  def maybe_handle_approval_request(
        port,
        "item/tool/call",
        %{"id" => id, "params" => params} = payload,
        payload_string,
        on_message,
        metadata,
        tool_executor,
        _auto_approve_requests,
        false
      ) do
    tool_name = Messages.tool_call_name(params)
    arguments = Messages.tool_call_arguments(params)

    result = Messages.normalize_tool_result(tool_executor.(tool_name, arguments))

    Rpc.send_message(port, %{"id" => id, "result" => result})

    event =
      case result do
        %{"success" => true} -> :tool_call_completed
        _ when is_nil(tool_name) -> :unsupported_tool_call
        _ -> :tool_call_failed
      end

    Messages.emit_message(on_message, event, %{payload: payload, raw: payload_string}, metadata)

    :approved
  end

  def maybe_handle_approval_request(
        port,
        "execCommandApproval",
        %{"id" => id} = payload,
        payload_string,
        on_message,
        metadata,
        _tool_executor,
        auto_approve_requests,
        false
      ) do
    approve_or_require(port, id, "approved_for_session", payload, payload_string, on_message, metadata, auto_approve_requests)
  end

  def maybe_handle_approval_request(
        port,
        "applyPatchApproval",
        %{"id" => id} = payload,
        payload_string,
        on_message,
        metadata,
        _tool_executor,
        auto_approve_requests,
        false
      ) do
    approve_or_require(port, id, "approved_for_session", payload, payload_string, on_message, metadata, auto_approve_requests)
  end

  def maybe_handle_approval_request(
        port,
        "item/fileChange/requestApproval",
        %{"id" => id} = payload,
        payload_string,
        on_message,
        metadata,
        _tool_executor,
        auto_approve_requests,
        false
      ) do
    approve_or_require(port, id, "acceptForSession", payload, payload_string, on_message, metadata, auto_approve_requests)
  end

  def maybe_handle_approval_request(
        port,
        "item/tool/requestUserInput",
        %{"id" => id, "params" => params} = payload,
        payload_string,
        on_message,
        metadata,
        _tool_executor,
        auto_approve_requests,
        false
      ) do
    maybe_auto_answer_tool_request_user_input(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  def maybe_handle_approval_request(
        _port,
        _method,
        _payload,
        _payload_string,
        _on_message,
        _metadata,
        _tool_executor,
        _auto_approve_requests,
        false
      ) do
    :unhandled
  end

  @spec maybe_handle_approval_request(
          port(),
          String.t(),
          map(),
          String.t(),
          (map() -> term()),
          map(),
          (term(), term() -> term()),
          boolean()
        ) :: :approved | :approval_required | :input_required | :unhandled
  def maybe_handle_approval_request(port, method, payload, payload_string, on_message, metadata, tool_executor, auto_approve_requests) do
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    maybe_handle_approval_request(port, method, payload, payload_string, on_message, metadata, tool_executor, auto_approve_requests, false)
  end

  defp approve_or_require(port, id, decision, payload, payload_string, on_message, metadata, true) do
    Rpc.send_message(port, %{"id" => id, "result" => %{"decision" => decision}})

    Messages.emit_message(
      on_message,
      :approval_auto_approved,
      %{payload: payload, raw: payload_string, decision: decision},
      metadata
    )

    :approved
  end

  defp approve_or_require(_port, _id, _decision, _payload, _payload_string, _on_message, _metadata, false) do
    :approval_required
  end

  defp maybe_auto_answer_tool_request_user_input(port, id, params, payload, payload_string, on_message, metadata, true) do
    case UserInputAnswers.approval_answers(params) do
      {:ok, answers, decision} ->
        Rpc.send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        Messages.emit_message(
          on_message,
          :approval_auto_approved,
          %{payload: payload, raw: payload_string, decision: decision},
          metadata
        )

        :approved

      :error ->
        reply_with_non_interactive_tool_input_answer(port, id, params, payload, payload_string, on_message, metadata)
    end
  end

  defp maybe_auto_answer_tool_request_user_input(port, id, params, payload, payload_string, on_message, metadata, false) do
    reply_with_non_interactive_tool_input_answer(port, id, params, payload, payload_string, on_message, metadata)
  end

  defp reply_with_non_interactive_tool_input_answer(port, id, params, payload, payload_string, on_message, metadata) do
    case UserInputAnswers.unavailable_answers(params) do
      {:ok, answers} ->
        Rpc.send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        Messages.emit_message(
          on_message,
          :tool_input_auto_answered,
          %{payload: payload, raw: payload_string, answer: UserInputAnswers.non_interactive_answer()},
          metadata
        )

        :approved

      :error ->
        :input_required
    end
  end

  defp deny_for_pause(port, "item/tool/call", id, payload, payload_string, on_message, metadata) do
    Rpc.send_message(port, %{"id" => id, "result" => %{"success" => false, "output" => "Agent pause is in progress; tool execution is unavailable."}})
    Messages.emit_message(on_message, :tool_call_failed, %{payload: payload, raw: payload_string}, metadata)
    :approved
  end

  defp deny_for_pause(port, _method, id, payload, payload_string, on_message, metadata) do
    Rpc.send_message(port, %{"id" => id, "result" => %{"decision" => "declined"}})
    Messages.emit_message(on_message, :approval_required, %{payload: payload, raw: payload_string}, metadata)
    :approved
  end
end
