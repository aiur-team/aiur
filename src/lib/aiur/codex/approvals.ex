defmodule Aiur.Codex.Approvals do
  @moduledoc """
  Codex approval request and tool-call servicing for app-server turn methods.
  """

  alias Aiur.AgentRunner.ToolExecutor
  alias Aiur.AppServer.{Messages, ToolCallIdentity, ToolCallLedger}
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
          map(),
          boolean()
        ) :: :approved | :approval_required | :input_required | :unhandled | {:error, :port_closed}
  def maybe_handle_approval_request(
        port,
        method,
        payload,
        payload_string,
        on_message,
        metadata,
        tool_executor,
        auto_approve_requests,
        context,
        paused?
      ) do
    case {method, payload, paused?} do
      {"item/tool/call", %{"id" => id, "params" => params}, false} ->
        handle_tool_call(port, id, params, payload, payload_string, on_message, metadata, tool_executor, context)

      _ ->
        maybe_handle_approval_request(
          port,
          method,
          payload,
          payload_string,
          on_message,
          metadata,
          tool_executor,
          auto_approve_requests,
          paused?
        )
    end
  end

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
        ) :: :approved | :approval_required | :input_required | :unhandled | {:error, :port_closed}
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
    handle_tool_call(port, id, params, payload, payload_string, on_message, metadata, tool_executor, nil)
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
        ) :: :approved | :approval_required | :input_required | :unhandled | {:error, :port_closed}
  def maybe_handle_approval_request(port, method, payload, payload_string, on_message, metadata, tool_executor, auto_approve_requests) do
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    maybe_handle_approval_request(port, method, payload, payload_string, on_message, metadata, tool_executor, auto_approve_requests, false)
  end

  defp approve_or_require(port, id, decision, payload, payload_string, on_message, metadata, true) do
    with :ok <- send_response(port, %{"id" => id, "result" => %{"decision" => decision}}) do
      Messages.emit_message(
        on_message,
        :approval_auto_approved,
        %{payload: payload, raw: payload_string, decision: decision},
        metadata
      )

      :approved
    end
  end

  defp approve_or_require(_port, _id, _decision, _payload, _payload_string, _on_message, _metadata, false) do
    :approval_required
  end

  defp handle_tool_call(port, id, params, payload, payload_string, on_message, metadata, tool_executor, context) do
    tool_name = Messages.tool_call_name(params)
    arguments = Messages.tool_call_arguments(params)
    call_id = Messages.tool_call_id(params, nil)
    invocation_id = call_id || id

    result =
      context
      |> execute_tool_call(params, tool_name, arguments, invocation_id, tool_executor)
      |> normalize_ledger_outcome()

    with :ok <- send_response(port, %{"id" => id, "result" => result}) do
      event =
        case result do
          %{"success" => true} -> :tool_call_completed
          _ when is_nil(tool_name) -> :unsupported_tool_call
          _ -> :tool_call_failed
        end

      Messages.emit_message(on_message, event, %{payload: payload, raw: payload_string}, metadata)
      :approved
    end
  end

  defp maybe_auto_answer_tool_request_user_input(port, id, params, payload, payload_string, on_message, metadata, true) do
    case UserInputAnswers.approval_answers(params) do
      {:ok, answers, decision} ->
        with :ok <- send_response(port, %{"id" => id, "result" => %{"answers" => answers}}) do
          Messages.emit_message(
            on_message,
            :approval_auto_approved,
            %{payload: payload, raw: payload_string, decision: decision},
            metadata
          )

          :approved
        end

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
        with :ok <- send_response(port, %{"id" => id, "result" => %{"answers" => answers}}) do
          Messages.emit_message(
            on_message,
            :tool_input_auto_answered,
            %{payload: payload, raw: payload_string, answer: UserInputAnswers.non_interactive_answer()},
            metadata
          )

          :approved
        end

      :error ->
        :input_required
    end
  end

  defp deny_for_pause(port, "item/tool/call", id, payload, payload_string, on_message, metadata) do
    with :ok <-
           send_response(port, %{"id" => id, "result" => %{"success" => false, "output" => "Agent pause is in progress; tool execution is unavailable."}}) do
      Messages.emit_message(on_message, :tool_call_failed, %{payload: payload, raw: payload_string}, metadata)
      :approved
    end
  end

  defp deny_for_pause(port, _method, id, payload, payload_string, on_message, metadata) do
    with :ok <- send_response(port, %{"id" => id, "result" => %{"decision" => "declined"}}) do
      Messages.emit_message(on_message, :approval_required, %{payload: payload, raw: payload_string}, metadata)
      :approved
    end
  end

  defp send_response(port, payload) do
    Rpc.send_message(port, payload)
    :ok
  rescue
    ArgumentError -> {:error, :port_closed}
  end

  defp tool_call_scope(%{tool_call_scope: scope}), do: scope
  defp tool_call_scope(_context), do: nil

  defp execute_tool_call(context, params, tool_name, arguments, invocation_id, tool_executor) do
    execute = fn ->
      tool_executor
      |> ToolExecutor.execute(tool_name, arguments, invocation_id)
      |> Messages.normalize_tool_result(context)
    end

    case ToolCallIdentity.resolve(
           tool_call_scope(context),
           params,
           tool_name,
           arguments,
           tool_call_thread_id(context)
         ) do
      :untracked ->
        execute.()

      {:ok, identity, fingerprint} ->
        ToolCallLedger.execute(identity, fingerprint, execute, tool_call_ledger(context))

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_ledger_outcome({:error, :conflicting_invocation}) do
    %{"success" => false, "output" => "Refusing conflicting reuse of a dynamic tool call identity."}
  end

  defp normalize_ledger_outcome({:error, :outcome_uncertain}) do
    %{"success" => false, "output" => "Dynamic tool outcome is uncertain; refusing to execute it again."}
  end

  defp normalize_ledger_outcome({:error, :missing_thread_identity}) do
    %{"success" => false, "output" => "Dynamic tool call is missing a stable provider thread identity."}
  end

  defp normalize_ledger_outcome({:error, reason}) do
    %{"success" => false, "output" => "Dynamic tool ledger unavailable: #{inspect(reason)}"}
  end

  defp normalize_ledger_outcome(result), do: result

  defp tool_call_thread_id(%{tool_call_thread_id: thread_id}), do: thread_id
  defp tool_call_thread_id(_context), do: nil

  defp tool_call_ledger(%{tool_call_ledger: server}), do: server
  defp tool_call_ledger(_context), do: ToolCallLedger
end
