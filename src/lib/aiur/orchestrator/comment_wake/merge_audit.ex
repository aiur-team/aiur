defmodule Aiur.Orchestrator.CommentWake.MergeAudit do
  @moduledoc "Merger attribution checks and alerts."

  require Logger

  @doc false
  @spec audit_merge_attribution(String.t() | integer(), String.t() | nil, function(), function()) :: term()
  def audit_merge_attribution(
        identifier,
        merged_by_login,
        merger_allowed_fun,
        emit_alert_fun
      ) do
    case safely_check_merger(merger_allowed_fun, merged_by_login) do
      {:ok, true} ->
        :ok

      # No login at all is "we do not know who merged this", not "somebody
      # unauthorized merged this". `merged_by_login` comes from
      # `get_in(pr, ["merged_by", "login"])`, which is absent whenever the PR
      # payload is the shape that does not carry a merger, or the read that
      # would have filled it failed. Reporting that as an unauthorized merge
      # makes a critical security alert cry wolf — and a muted guard cannot
      # tell a real unauthorized merge from a failed read, which is the exact
      # thing it exists to distinguish. Report it as what it is: the
      # attribution could not be checked.
      :unknown_merger ->
        Logger.error(
          "PR merge attribution missing: issue_identifier=#{identifier} " <>
            "merged_by=nil (the merge payload carried no merger login)"
        )

        safely_emit_merge_alert(
          emit_alert_fun,
          "ticket.#{identifier}.merge.attribution_check_failed",
          message: "PR merge attribution could not be determined for ticket #{identifier}.",
          issue: to_string(identifier),
          reason:
            "The merge carried no merger login, so the human merger allowlist could not be checked. " <>
              "This is an unverified merge, not a detected unauthorized one.",
          needs_attention: true,
          severity: "critical"
        )

      {:ok, false} ->
        safely_emit_merge_alert(
          emit_alert_fun,
          "ticket.#{identifier}.merge.unauthorized_merger",
          message: "Unauthorized PR merger #{inspect(merged_by_login)} detected for ticket #{identifier}.",
          issue: to_string(identifier),
          reason: "PR merged by #{inspect(merged_by_login)} who is not in the human merger allowlist.",
          needs_attention: true,
          severity: "critical"
        )

      {:error, reason} ->
        Logger.error(
          "PR merge attribution check failed: issue_identifier=#{identifier} " <>
            "merged_by=#{inspect(merged_by_login)} reason=#{inspect(reason)}"
        )

        safely_emit_merge_alert(
          emit_alert_fun,
          "ticket.#{identifier}.merge.attribution_check_failed",
          message: "PR merge attribution check failed for ticket #{identifier}.",
          issue: to_string(identifier),
          reason: "PR merged by #{inspect(merged_by_login)}, but the human merger allowlist check failed: #{inspect(reason)}.",
          needs_attention: true,
          severity: "critical"
        )
    end
  end

  defp safely_check_merger(_merger_allowed_fun, nil), do: :unknown_merger
  defp safely_check_merger(_merger_allowed_fun, ""), do: :unknown_merger

  defp safely_check_merger(merger_allowed_fun, merged_by_login) do
    {:ok, merger_allowed_fun.(merged_by_login) == true}
  rescue
    error -> {:error, {:exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp safely_emit_merge_alert(emit_alert_fun, name, opts) do
    emit_alert_fun.(name, opts)
  rescue
    error ->
      Logger.error("PR merge attribution alert failed: name=#{name} reason=#{Exception.message(error)}")
      :error
  catch
    kind, reason ->
      Logger.error("PR merge attribution alert failed: name=#{name} reason=#{inspect({kind, reason})}")
      :error
  end
end
