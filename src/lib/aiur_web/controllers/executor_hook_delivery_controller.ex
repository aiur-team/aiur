defmodule AiurWeb.ExecutorHookDeliveryController do
  @moduledoc "Returns only the envelope the attached Executor hook should print."
  use Phoenix.Controller, formats: [:json]

  alias Aiur.Executor.{HookPayload, Session}
  alias Aiur.Orchestrator.OperatorMessages.ExecutorHookClaims

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    deadline = System.monotonic_time(:millisecond) + 1_400
    conn = Plug.Conn.fetch_query_params(conn)

    with true <- valid_continuation_flag?(conn.body_params),
         {:ok, hook} <- HookPayload.normalize(conn.body_params, conn.query_params["harness"]),
         boundary when boundary in [:tool, :prompt, :stop] <- boundary(hook),
         {:ok, binding} <- current(deadline) do
      attempt = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      opts = [deadline: deadline, attempt: attempt, session_id: hook.session_id, harness: hook.harness, generation: binding.generation]

      case ExecutorHookClaims.claim_executor_hook_batch(binding.binding_id, boundary, opts) do
        {:ok, output} -> emit(conn, output, attempt)
        _ -> send_resp(conn, 204, "")
      end
    else
      _ -> send_resp(conn, 204, "")
    end
  end

  defp valid_continuation_flag?(%{"stop_hook_active" => value}), do: is_boolean(value)
  defp valid_continuation_flag?(_body), do: true

  defp current(deadline) do
    GenServer.call(Session, :current, max(1, deadline - System.monotonic_time(:millisecond)))
  catch
    :exit, _ -> :none
  end

  defp boundary(%{event: "Stop", stop_hook_active: true}), do: :none
  defp boundary(%{agent_id: id}) when is_binary(id), do: :none
  defp boundary(%{event: "Stop"}), do: :stop
  defp boundary(%{event: "PostToolUse"}), do: :tool
  defp boundary(%{event: "UserPromptSubmit"}), do: :prompt
  defp boundary(_hook), do: :none

  defp emit(conn, output, attempt) do
    conn |> put_resp_content_type("application/json") |> send_resp(200, output)
  rescue
    error ->
      ExecutorHookClaims.restore(Aiur.Orchestrator, attempt)
      reraise error, __STACKTRACE__
  end
end
