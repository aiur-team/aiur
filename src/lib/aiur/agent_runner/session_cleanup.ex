defmodule Aiur.AgentRunner.SessionCleanup do
  @moduledoc false
  alias Aiur.AgentRunner.SessionIdentity
  alias Aiur.CodingAgent
  alias Aiur.Workspace.Ownership

  @spec stop(map(), map() | nil, function()) :: term()
  def stop(session, ownership, stop_fun) do
    if Process.get(:handoff_detached), do: :ok, else: cleanup(session, ownership, stop_fun)
  end

  defp cleanup(session, ownership, stop_fun) do
    try do
      case stop_fun.(session) do
        {:ok, :cleanup_proven} ->
          _ = Ownership.mark_provider_cleanup_succeeded(ownership)
          :ok

        :ok ->
          _ = Ownership.mark_provider_cleanup_unknown(ownership)
          :ok

        cleanup_failure ->
          _ = Ownership.mark_provider_cleanup_unknown(ownership)
          cleanup_failure
      end
    after
      CodingAgent.revoke_launch_telemetry(SessionIdentity.session_backend!(session), Map.get(session, :telemetry_launch))
    end
  catch
    kind, reason ->
      _ = Ownership.mark_provider_cleanup_unknown(ownership)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end
end
