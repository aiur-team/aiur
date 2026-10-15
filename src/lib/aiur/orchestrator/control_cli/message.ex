defmodule Aiur.Orchestrator.ControlCLI.Message do
  @moduledoc false
  alias Aiur.AgentChat
  import Aiur.Orchestrator.ControlCLI, only: [control_status_snapshot: 0]
  import Aiur.ControlCLI.Protocol
  import Aiur.Orchestrator.ControlCLI.Output
  # `aiur message` has the same shape: `{:ok, request_id}` is a queue handle,
  # not a delivery receipt (#1824). One target means a much smaller budget than
  # `resume --all` needs, and an operator nudge to a busy agent is normally
  # claimed at its next checkpoint rather than inside any window we could
  # afford to wait — so this window exists to catch the fast claim, not to
  # decide the outcome. Anything still pending when it elapses is reported as
  # queued, which is what actually happened.
  @message_confirm_timeout_ms 1_500
  @message_confirm_poll_ms 100
  @doc """
  Send Executor text to one running agent.

  `message_id` names this one send (#2717). When it is `nil`, a new id is
  created. If the daemon does not answer in time, the output prints the id
  and the exact command that retries this send without queueing a copy.
  """
  @spec message(String.t(), String.t(), String.t() | nil) :: :ok
  def message(issue, text, message_id \\ nil) when is_binary(issue) and is_binary(text) do
    message_id = if is_binary(message_id) and message_id != "", do: message_id, else: new_message_id()

    guarded("message", fn ->
      issue
      |> message_status(text, message_id, control_status_snapshot())
      |> exit_marker()
    end)
  end

  defp new_message_id, do: "cli-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  defp message_status(issue, text, message_id, statuses) when is_list(statuses) do
    case Enum.find(statuses, &target_matches?(&1, issue)) do
      nil ->
        print_failure(:message, %{identifier: issue, issue_id: issue}, :no_running_agent)
        1

      status ->
        deliver_message(status, issue, text, message_id)
    end
  end

  defp message_status(_issue, _text, _message_id, error) when error in [:timeout, :unavailable] do
    print_orchestrator_status_error(error)
    control_query_exit_code(error)
  end

  # Empty/whitespace-only and over-long text are validated downstream by
  # Orchestrator.send_operator_message (the shared delivery path), which returns
  # {:error, :empty_message | :message_too_long}; we surface those via format_reason.
  defp deliver_message(status, issue, text, message_id) do
    case send_message(canonical_identifier(status), text, message_id) do
      {:ok, request_id} ->
        report_message_outcome(status, request_id, await_message_delivery(request_id))
        0

      # The daemon did not answer in time, but it may still queue the message
      # (#2717). That is an unknown outcome, not a failure. Only a retry with
      # this send's message id is deduplicated, so the output prints it.
      {:error, {:outcome_unknown, _info}} ->
        IO.puts(
          "aiur: outcome unknown for message to #{display_identifier(status)}: the daemon did not answer in time " <>
            "and may still queue it (message id #{message_id}). Check the ticket log before you send it again. " <>
            "To retry this send without a duplicate, run: aiur message #{issue} --message-id #{message_id} #{shell_quote(text)}"
        )

        control_query_exit_code(:timeout)

      {:error, reason} ->
        print_failure(:message, status, reason)
        control_query_exit_code(reason)
    end
  end

  defp shell_quote(text), do: "'" <> String.replace(text, "'", "'\\''") <> "'"

  # A successful send returns a queue handle, not a delivery receipt: the
  # message is enqueued for the agent and is claimed later, and with
  # `fallback: :queue_next` deferred delivery is the expected case rather than
  # the exception (#1824). So poll the queue item this invocation created for a
  # short window and say only what was observed — "delivered" once the agent
  # has claimed it, "queued" otherwise. Both are successful enqueues, so both
  # exit 0; only the claim about what happened differs.
  defp await_message_delivery(request_id) when is_integer(request_id) do
    deadline = System.monotonic_time(:millisecond) + message_confirm_timeout_ms()
    poll_message_delivery(request_id, deadline)
  end

  defp await_message_delivery(_request_id), do: :unobserved

  defp poll_message_delivery(request_id, deadline) do
    case message_delivery_status(request_id, max(remaining_ms(deadline), @message_confirm_poll_ms)) do
      # The agent has the message: claimed (`:delivered`) or already acted on
      # it (`:consumed`). This is the only outcome that may claim delivery.
      {:ok, status} when status in [:delivered, :consumed] ->
        :delivered

      # Settled without reaching the agent — no point spending the rest of the
      # budget, and "unconfirmed" would understate a known non-delivery.
      {:ok, status} when status in [:failed, :superseded] ->
        {:undelivered, status}

      # Still `:pending`, or the status is unreadable (the daemon is busy, the
      # item is not visible yet). Neither proves anything, so keep waiting.
      {:ok, _pending} ->
        retry_message_delivery(request_id, deadline)

      {:error, _reason} ->
        retry_message_delivery(request_id, deadline)
    end
  end

  defp retry_message_delivery(request_id, deadline) do
    if remaining_ms(deadline) <= @message_confirm_poll_ms do
      :queued
    else
      Process.sleep(@message_confirm_poll_ms)
      poll_message_delivery(request_id, deadline)
    end
  end

  defp report_message_outcome(status, request_id, :delivered) do
    IO.puts("aiur: delivered message to #{display_identifier(status)} (request #{request_id})")
  end

  defp report_message_outcome(status, request_id, {:undelivered, queue_status}) do
    IO.puts("aiur: queued message for #{display_identifier(status)} (request #{request_id}); not delivered (#{queue_status})")
  end

  defp report_message_outcome(status, request_id, _queued) do
    IO.puts("aiur: queued message for #{display_identifier(status)} (request #{request_id}); delivery is unconfirmed")
  end

  defp send_message(identifier, text, message_id) do
    case Application.get_env(:aiur, :agent_control_cli_message_fun, &AgentChat.send/3) do
      fun when is_function(fun, 3) -> fun.(identifier, text, message_id: message_id)
      fun when is_function(fun, 2) -> fun.(identifier, text)
    end
  end

  # The read never outlives the confirmation budget, so `message` cannot walk
  # past the launcher's control-RPC timeout waiting for an answer.
  defp message_delivery_status(request_id, timeout_ms) do
    Application.get_env(:aiur, :agent_control_cli_message_status_fun, &AgentChat.delivery_status/2).(
      request_id,
      timeout_ms
    )
  end

  defp message_confirm_timeout_ms do
    Application.get_env(:aiur, :agent_control_cli_message_confirm_timeout_ms, @message_confirm_timeout_ms)
  end

  defp remaining_ms(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
