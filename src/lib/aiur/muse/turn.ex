defmodule Aiur.Muse.Turn do
  @moduledoc "Runner-owned native Muse turn admission and outcome handling."

  alias Aiur.AgentTools.MCP
  alias Aiur.AppServer.Messages
  alias Aiur.Muse.{Protocol, Transport, TurnLoop}

  @spec run(map(), String.t(), map(), keyword()) :: {:ok, map()} | {:paused, map()} | {:error, term()}
  def run(session, prompt, issue, opts \\ [])

  def run(%{port: _port, gateway: gateway, thread_id: _session_id} = session, prompt, issue, opts)
      when is_binary(prompt) and byte_size(prompt) > 0 do
    attempt = Keyword.get(opts, :attempt_id, make_ref())

    with {:ok, binding} <- MCP.bind(gateway, attempt) do
      try do
        start_and_wait(session, prompt, issue, opts, binding)
      after
        MCP.unbind(gateway, binding)
      end
    end
  end

  def run(_, _, _, _), do: {:error, :invalid_native_turn}

  defp start_and_wait(%{port: port, thread_id: session_id} = session, prompt, issue, opts, binding) do
    command_id = Protocol.command_id()
    request_id = System.unique_integer([:positive])
    frame_opts = [command_id: command_id]
    frame_opts = if is_binary(session[:effort]), do: Keyword.put(frame_opts, :reasoning_effort, session.effort), else: frame_opts
    frame = Protocol.turn_start_frame(request_id, session_id, prompt, frame_opts)
    timeout = Keyword.get(opts, :turn_timeout_ms, Aiur.Config.agent_turn_timeout_ms())
    deadline = System.monotonic_time(:millisecond) + timeout
    on_notification = fn notification -> send(self(), {:muse_prestart, notification}) end

    with {:ok, result} <- Transport.request(port, frame, timeout, on_notification),
         {:accepted, receipt} <- Protocol.turn_start_result(result, command_id) do
      turn_id = receipt["turnId"]
      metadata = Map.get(session, :metadata, %{})
      on_message = Keyword.get(opts, :on_message, &Messages.default_on_message/1)
      session_id_for_run = "#{session_id}-#{turn_id}"

      Messages.emit_message(on_message, :session_started, %{session_id: session_id_for_run, thread_id: session_id, turn_id: turn_id}, metadata)
      delivery_result = notify_delivery(opts, turn_id)
      native_result = TurnLoop.await(session, turn_id, issue, binding, opts, max(deadline - System.monotonic_time(:millisecond), 0))

      delivery_outcome(delivery_result, native_result, turn_id)
    else
      {:error, reason} -> {:error, {:turn_start_failed, reason}}
    end
  end

  defp notify_delivery(opts, turn_id) do
    callback = Keyword.get(opts, :on_provider_delivery, fn _ -> :ok end)

    case callback.(%{transport: :muse_msp, turn_id: turn_id}) do
      {:error, reason} -> {:error, reason}
      _acknowledged -> :ok
    end
  rescue
    error -> {:error, {:callback_exception, error.__struct__}}
  catch
    kind, _reason -> {:error, {:callback_failure, kind}}
  end

  defp delivery_outcome(:ok, native_result, _turn_id), do: native_result

  defp delivery_outcome({:error, cause}, native_result, turn_id) do
    details = Map.merge(%{turn_id: turn_id, cause: cause}, native_outcome_details(native_result))

    {:error, {:provider_delivery_ack_failed, details}}
  end

  defp native_outcome_details({:ok, _}), do: %{native_outcome: :completed}
  defp native_outcome_details({:paused, payload}), do: %{native_outcome: :paused, native_pause: Map.get(payload, :control)}
  defp native_outcome_details({:error, reason}), do: %{native_outcome: :failed, native_failure: reason}
end
