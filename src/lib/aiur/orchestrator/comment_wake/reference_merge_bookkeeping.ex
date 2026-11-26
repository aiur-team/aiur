defmodule Aiur.Orchestrator.CommentWake.ReferenceMergeBookkeeping do
  @moduledoc false

  require Logger

  alias Aiur.GitHub.Config
  alias Aiur.Orchestrator.MergeStateWriter
  alias Aiur.Orchestrator.MergeTransition
  alias Aiur.RecentMergeStore

  @spec write(String.t() | integer(), keyword(), function()) :: :ok
  def write(identifier, opts, emit_alert_fun) do
    [
      {:merge_queued_label_cleanup, fn -> MergeStateWriter.clear_nonterminal_merge_queued(identifier, opts) end},
      {:reconciliation_marker, fn -> mark_ticket_reconciled(identifier, opts) end}
    ]
    |> Enum.each(fn {step, write} ->
      case write.() do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("PR reference merge bookkeeping deferred: issue_identifier=#{identifier} step=#{step} reason=#{inspect(reason)}")
          maybe_emit_bookkeeping_failed_alert(emit_alert_fun, identifier, step, reason)

        other ->
          Logger.warning("PR reference merge bookkeeping deferred: issue_identifier=#{identifier} step=#{step} result=#{inspect(other)}")
      end
    end)

    :ok
  end

  defp mark_ticket_reconciled(identifier, opts) do
    mark_ticket_reconciled_fun =
      Keyword.get(opts, :mark_ticket_reconciled_fun, fn merge_id, ticket_id ->
        RecentMergeStore.mark_ticket_reconciled(merge_id, ticket_id)
      end)

    with number when is_integer(number) <- opts[:pr_number],
         repo when is_binary(repo) <- merge_repository(opts),
         :ok <- mark_ticket_reconciled_fun.("#{repo}##{number}", to_string(identifier)) do
      :ok
    else
      {:error, :merge_not_found} -> :ok
      {:error, _reason} = error -> error
      _other -> :ok
    end
  end

  defp merge_repository(opts) do
    Keyword.get(opts, :repo_fun, &Config.repo/0).()
  rescue
    _error -> nil
  end

  defp maybe_emit_bookkeeping_failed_alert(_emit_alert_fun, _identifier, :reconciliation_marker, {:store_unavailable, _health}),
    do: :ok

  defp maybe_emit_bookkeeping_failed_alert(emit_alert_fun, identifier, step, reason) do
    reason_name = MergeTransition.reason_name(reason)

    emit_alert_fun.(
      "ticket.#{identifier}.agent.attention.merge_reference_bookkeeping_failed",
      message: "Merged PR reference bookkeeping failed for ticket #{identifier} at step #{step} (#{reason_name}).",
      issue: identifier,
      reason: "The reference merge bookkeeping step #{step} failed (#{reason_name}).",
      needs_attention: true,
      severity: "warning",
      central: true
    )
  end
end
