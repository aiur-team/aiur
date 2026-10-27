defmodule Aiur.Commands.NativeCapture.Claude do
  @moduledoc "Translate Claude native requests into deferred Commands."

  require Logger

  alias Aiur.Commands.NativeCapture.{Release, Request}
  alias Aiur.Config
  alias Aiur.DecisionStore

  @spec handle(port() | pid(), term(), map(), map()) :: term()
  def handle(port, id, params, ctx) do
    if Config.decisions_native_capture?(:claude) do
      port |> Request.capture(id, params, ctx, :claude) |> maybe_release(port, params, ctx)
    else
      :unhandled
    end
  end

  defp maybe_release({:held, ref, info}, port, %{"holdable" => false}, ctx) do
    Release.release_all(%{held_native_questions: %{ref => info}, native_release_store: Map.get(ctx, :store, DecisionStore)}, :not_holdable, &ctx.send_response.(port, &1))
    :approved
  end

  defp maybe_release(result, _port, _params, _ctx), do: result

  @doc "Release deferred Commands owned by a previous, non-resumable Claude thread."
  @spec release_stale(map(), map()) :: :ok
  def release_stale(session, issue) do
    if Config.decisions_native_capture?(:claude), do: do_release_stale(session, issue)
    :ok
  catch
    :exit, reason -> warn_release_failure(session, issue, reason)
  end

  defp do_release_stale(session, issue) do
    store = Map.get(session, :store, DecisionStore)
    prefix = "claude:#{session.thread_id}:"

    store
    |> DecisionStore.list()
    |> Enum.filter(fn decision ->
      decision.decision_status == :open and decision.ticket.identifier == issue.identifier and
        match?(%{harness: :claude, hold: :deferred}, decision.native) and
        not String.starts_with?(decision.native.native_ref, prefix)
    end)
    |> Enum.each(fn decision ->
      data = %{native_ref: decision.native.native_ref, reason: :session_gone, at: DateTime.utc_now()}

      case DecisionStore.record_command_fact(decision.decision_id, :native_released, data, server: store) do
        {:ok, _result} -> :ok
        {:error, reason} -> warn_release_failure(session, issue, {decision.decision_id, reason})
      end
    end)
  end

  defp warn_release_failure(session, issue, reason) do
    Logger.warning("Claude stale native release failed ticket=#{issue.identifier} thread=#{session.thread_id}: #{inspect(reason)}")
    :ok
  end
end
