defmodule Aiur.AgentControlCLI.KeyedMessage do
  @moduledoc """
  `aiur message <n> --message-id KEY <text>` with a durable receipt.

  A caller that crashes and runs the same send again gets the first request id
  back and nothing is queued again, also after the worker consumed the message
  or the daemon restarted. A first send that queued nothing may run again: the
  queue still refuses a second copy under the same message id (#2717).
  """

  import Aiur.ControlCLI.Protocol

  alias Aiur.ControlCall.KeyedReceipt
  alias Aiur.Orchestrator.ControlCLI.Message

  @spec message(String.t(), String.t(), String.t() | nil) :: :ok
  def message(issue, text, key \\ nil)

  def message(issue, text, key) when is_binary(issue) and is_binary(text) and is_binary(key) and key != "" do
    guarded("message", fn -> issue |> run(text, key) |> exit_marker() end)
  end

  def message(issue, text, _no_key), do: Message.message(issue, text, nil)

  defp run(issue, text, key) do
    send = fn ->
      {code, request_id} = Message.send_and_report(issue, text, key)
      %{"exit" => code, "request_id" => request_id}
    end

    case KeyedReceipt.run("message", key, {issue, text}, send) do
      {:new, %{"exit" => code}} ->
        code

      {:replay, %{"exit" => code, "request_id" => request_id}} when is_integer(request_id) ->
        IO.puts("aiur: message #{key} already sent to #{issue} (request #{request_id}); nothing queued again")
        code

      {:replay, _nothing_queued} ->
        send.()["exit"]

      {:error, reason} ->
        control_error("aiur: message #{key} was not sent: #{KeyedReceipt.describe(reason)}")
        KeyedReceipt.exit_code(reason)
    end
  end
end
