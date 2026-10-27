defmodule Aiur.AgentCompaction.Handoff do
  @moduledoc false

  require Logger

  alias Aiur.AgentCompaction.{Config, Orchestrator, Store}
  alias Aiur.Config.Schema.Compaction

  @type status_callback :: (atom(), String.t() | nil, term() -> term())

  @spec run(map(), map(), map()) :: :ok
  def run(turn_context, session, issue) do
    config = Config.settings()
    tokens = token_count(turn_context, issue, config)
    on_status = status_callback(turn_context, session, issue)

    execute(issue.state, session, issue.identifier, turn_context.turn_number, config, tokens, on_status)
  rescue
    error ->
      Logger.warning("Compaction failed; preserving normal review handoff identifier=#{issue.identifier} reason=#{Exception.message(error)}")
      :ok
  end

  @spec execute(String.t(), map(), String.t(), non_neg_integer(), Compaction.t(), non_neg_integer() | nil, status_callback()) :: :ok
  def execute("human-review", session, identifier, turn_number, config, tokens, on_status) do
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

  def execute(_state, _session, _identifier, _turn_number, _config, _tokens, _on_status), do: :ok

  defp current_agent_total_tokens(%{orchestrator: orchestrator}, issue) do
    case Aiur.Orchestrator.status(orchestrator, 5_000) do
      entries when is_list(entries) ->
        case Enum.find(entries, &(Map.get(&1, :identifier) == issue.identifier)) do
          %{agent_total_tokens: tokens} when is_integer(tokens) and tokens >= 0 -> tokens
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _error -> nil
  end

  defp token_count(turn_context, issue, %{auto_trigger: %{enabled: true}}),
    do: current_agent_total_tokens(turn_context, issue)

  defp token_count(_turn_context, _issue, _config), do: nil

  defp status_callback(%{workspace: workspace, worker_host: worker_host}, app_session, issue) do
    fn status, thread_id, detail ->
      message =
        case status do
          :pending -> "Native Codex compaction pending"
          :completed -> "Native Codex compaction completed"
          :failed -> "Native Codex compaction failed: #{inspect(detail)}"
          :unsupported -> "Native compaction unsupported for this provider"
        end

      Aiur.Alerts.emit_custom("compaction.#{status}", message,
        issue: issue,
        workspace: workspace,
        worker_host: worker_host,
        reason: "Codex thread compaction #{status}",
        needs_attention: false,
        severity: if(status == :failed, do: "warning", else: "info"),
        observation_identity: Aiur.Issue.tracker_identity(issue),
        observation_source: %{kind: :agent_alert, name: "compaction.#{status}"},
        observation_provenance: %{
          run_id: Aiur.Boot.run_id(),
          session_id: thread_id || Map.get(app_session, :thread_id)
        },
        occurred_at: DateTime.utc_now()
      )
    end
  end

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

    case Orchestrator.trigger_compaction(Map.put(session, :backend, "codex"), "codex", turn_number, on_status: on_status) do
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
