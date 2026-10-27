defmodule Aiur.Commands.NativeCapture.Claude do
  @moduledoc "Translate Claude native requests into deferred Commands."

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
  @spec release_stale(map(), map()) :: :ok | {:error, term()}
  def release_stale(session, issue) do
    store = Map.get(session, :store, DecisionStore)
    prefix = "claude:#{session.thread_id}:"

    store
    |> DecisionStore.list()
    |> Enum.filter(fn decision ->
      decision.ticket.identifier == issue.identifier and
        match?(%{harness: :claude, hold: :deferred}, decision.native) and
        not String.starts_with?(decision.native.native_ref, prefix)
    end)
    |> Enum.reduce_while(:ok, fn decision, :ok ->
      data = %{native_ref: decision.native.native_ref, reason: :session_gone, at: DateTime.utc_now()}

      case DecisionStore.record_command_fact(decision.decision_id, :native_released, data, server: store) do
        {:ok, _result} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  catch
    :exit, reason -> {:error, reason}
  end
end
