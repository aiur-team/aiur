defmodule Aiur.AgentCompaction.CodexClient do
  @moduledoc """
  Codex app-server `thread/compact/start` JSON-RPC request.

  The method returns an empty result. Completion is reported through the
  deprecated `thread/compacted` notification, correlated by thread id.
  """

  require Logger

  @spec request_compact(port(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def request_compact(port, thread_id, opts \\ [])

  def request_compact(port, thread_id, opts) when is_port(port) do
    request_id = :erlang.unique_integer([:positive])
    deadline = System.monotonic_time(:millisecond) + timeout(opts)

    with {:ok, frame} <- build_request(thread_id, request_id),
         :ok <- send_request(port, frame) do
      notify_status(opts, :pending, thread_id, nil)

      with {:ok, response} <-
             Aiur.Codex.Rpc.await_response(port, request_id, remaining_ms(deadline), on_notification: fn payload -> route_notification(payload, thread_id, opts) end),
           :ok <- empty_response(response),
           {:ok, completion} <- await_completion(port, thread_id, deadline, opts) do
        notify_status(opts, :completed, thread_id, completion.turn_id)
        Logger.info("Codex thread compaction completed thread_id=#{thread_id} turn_id=#{completion.turn_id}")
        {:ok, completion}
      else
        {:error, reason} = error ->
          notify_status(opts, :failed, thread_id, reason)
          error
      end
    else
      {:error, reason} = error ->
        notify_status(opts, :failed, thread_id, reason)
        error
    end
  end

  def request_compact(_port, thread_id, _opts), do: {:error, {:invalid_thread_or_port, thread_id}}

  @doc false
  def build_request(thread_id, request_id \\ :erlang.unique_integer([:positive]))

  def build_request(thread_id, request_id) when is_binary(thread_id) and byte_size(thread_id) > 0 and is_integer(request_id) do
    {:ok, %{"id" => request_id, "method" => "thread/compact/start", "params" => %{"threadId" => thread_id}}}
  end

  def build_request(_, _), do: {:error, :invalid_thread_id}

  defp timeout(opts), do: Keyword.get(opts, :timeout_ms, 30_000)

  defp send_request(port, frame) do
    Aiur.Codex.Rpc.send_message(port, frame)
    :ok
  rescue
    ArgumentError -> {:error, :port_closed}
  end

  defp empty_response(response) when response == %{}, do: :ok
  defp empty_response(response), do: {:error, {:invalid_compaction_response, response}}

  defp route_notification(%{"method" => "thread/compacted", "params" => params}, expected_thread_id, _opts)
       when is_map(params) do
    turn_id = params["turnId"]

    if params["threadId"] == expected_thread_id and is_binary(turn_id) and turn_id != "" do
      Process.put(completion_key(expected_thread_id), turn_id)
    end

    :handled
  end

  defp route_notification(payload, thread_id, opts) do
    case Keyword.get(opts, :on_notification, fn _ -> :ignore end).(payload) do
      :handled ->
        :handled

      _ ->
        if get_in(payload, ["params", "threadId"]) == thread_id do
          notify_status(opts, :pending, thread_id, nil)
        end

        :ignore
    end
  end

  defp await_completion(port, thread_id, deadline, opts) do
    case Process.delete(completion_key(thread_id)) do
      turn_id when is_binary(turn_id) ->
        {:ok, %{thread_id: thread_id, turn_id: turn_id}}

      _ ->
        # The completion notification may follow the request response. Keep
        # the shared app-server reader active until it arrives or the same
        # bounded deadline expires.
        sentinel = :erlang.unique_integer([:positive])
        _ = await_completion_notification(port, sentinel, deadline, thread_id, opts)

        case Process.delete(completion_key(thread_id)) do
          turn_id when is_binary(turn_id) -> {:ok, %{thread_id: thread_id, turn_id: turn_id}}
          _ -> {:error, :compaction_completion_timeout}
        end
    end
  end

  defp await_completion_notification(port, sentinel, deadline, thread_id, opts) do
    case Aiur.Codex.Rpc.await_response(port, sentinel, remaining_ms(deadline), on_notification: fn payload -> route_notification(payload, thread_id, opts) end) do
      {:error, :response_timeout} -> :ok
      other -> other
    end
  end

  defp remaining_ms(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp completion_key(thread_id), do: {__MODULE__, :completion, thread_id}

  defp notify_status(opts, status, thread_id, detail) do
    case Keyword.get(opts, :on_status) do
      callback when is_function(callback, 3) -> callback.(status, thread_id, detail)
      _ -> :ok
    end
  end
end
