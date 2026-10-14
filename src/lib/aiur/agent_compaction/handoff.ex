defmodule Aiur.AgentCompaction.Handoff do
  @moduledoc false

  require Logger

  alias Aiur.AgentCompaction.{Config, Orchestrator, Store}
  alias Aiur.Config.Schema.Compaction

  @type status_callback :: (atom(), String.t() | nil, term() -> term())

  @spec run(String.t(), map(), String.t(), non_neg_integer(), Compaction.t(), non_neg_integer() | nil, status_callback()) :: :ok
  def run("human-review", session, identifier, turn_number, config, tokens, on_status) do
    backend = Map.get(session, :backend)

    cond do
      backend == "codex" and Config.should_compact_at_handoff?(config, tokens) ->
        compact_codex(session, identifier, turn_number, on_status)

      backend != "codex" and Config.trigger_requested_at_handoff?(config, tokens) and not Orchestrator.supported_backend?(backend) ->
        report_unsupported(session, identifier, on_status)

      true ->
        :ok
    end
  end

  def run(_state, _session, _identifier, _turn_number, _config, _tokens, _on_status), do: :ok

  defp compact_codex(session, identifier, turn_number, on_status) do
    thread_id = Map.get(session, :thread_id)
    prior = prior_state(identifier, thread_id, on_status)

    if prior == :unreadable or Orchestrator.already_attempted_for_thread?(prior, thread_id) do
      Logger.info("Codex compaction skipped for unchanged waiting session identifier=#{identifier}")
    else
      persist_and_compact(session, identifier, turn_number, on_status)
    end

    :ok
  end

  defp prior_state(identifier, thread_id, on_status) do
    case Store.load(identifier) do
      {:ok, state} ->
        recovered = Orchestrator.interrupted_pending_attempt(state, thread_id)
        if recovered != state, do: persist_recovered(identifier, recovered, thread_id, on_status)
        recovered

      {:error, reason} ->
        Logger.warning("Could not read prior Codex compaction state for #{identifier}; skipping compaction: #{inspect(reason)}")
        :unreadable
    end
  end

  defp persist_recovered(identifier, recovered, thread_id, on_status) do
    _ = Store.save(identifier, recovered)
    on_status.(:failed, thread_id, recovered["reason"])
  end

  defp persist_and_compact(session, identifier, turn_number, on_status) do
    thread_id = Map.get(session, :thread_id)

    case Store.save(identifier, %{"thread_id" => thread_id, "status" => "pending"}) do
      :ok -> run_codex_compaction(session, identifier, turn_number, on_status)
      {:error, reason} -> Logger.warning("Could not persist Codex compaction pending state for #{identifier}; skipping compaction: #{inspect(reason)}")
    end
  end

  defp run_codex_compaction(session, identifier, turn_number, on_status) do
    thread_id = Map.get(session, :thread_id)

    case Orchestrator.trigger_compaction(session, "codex", turn_number, on_status: on_status) do
      {:ok, :completed, state} ->
        _ = Store.save(identifier, %{"thread_id" => thread_id, "compacted_thread_id" => state.compacted_transcript_ref, "status" => "completed"})
        Logger.info("Codex compaction completed before review handoff identifier=#{identifier}")

      {:error, reason} ->
        _ = Store.save(identifier, %{"thread_id" => thread_id, "status" => "failed", "reason" => inspect(reason)})
        Logger.warning("Codex compaction failed; preserving normal review handoff identifier=#{identifier} reason=#{inspect(reason)}")
    end
  end

  defp report_unsupported(session, identifier, on_status) do
    thread_id = Map.get(session, :thread_id)

    prior =
      case Store.load(identifier) do
        {:ok, state} -> state
        {:error, _reason} -> nil
      end

    unless Orchestrator.already_attempted_for_thread?(prior, thread_id) do
      on_status.(:unsupported, thread_id, nil)
      if is_binary(thread_id), do: Store.save(identifier, %{"thread_id" => thread_id, "status" => "unsupported"})
    end

    :ok
  end
end
