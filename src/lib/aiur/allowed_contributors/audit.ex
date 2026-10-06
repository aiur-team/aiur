defmodule Aiur.AllowedContributors.Audit do
  @moduledoc """
  Append-only audit trail of every allowed-contributor intake decision.

  One ndjson record per decision — accept, reject, or deferred — naming the
  issue, the numeric author id, the reason, the allow-list commit SHA the
  decision was made against (`nil` when no allow-list was held), and which
  producer saw it. The same fields go to the daemon log, so the decision is
  greppable even when the file is not at hand. Logins are recorded only as a
  display aid; nothing reads them back as identity.
  """

  require Logger

  alias Aiur.DecisionLog

  @type decision :: :accept | :reject | :deferred

  @spec record(Path.t(), decision(), map(), term(), String.t() | nil, String.t()) :: :ok
  def record(path, decision, candidate, reason, sha, at) do
    record = %{
      "at" => at,
      "decision" => Atom.to_string(decision),
      "issue" => candidate.number,
      "author_id" => candidate.author_id,
      "author_login" => candidate.author_login,
      "reason" => format_reason(reason),
      "allowlist_sha" => sha,
      "source" => Atom.to_string(candidate.source)
    }

    Logger.info(
      "allowed_contributors decision=#{decision} issue=#{inspect(candidate.number)} " <>
        "author_id=#{inspect(candidate.author_id)} reason=#{record["reason"]} " <>
        "allowlist_sha=#{inspect(sha)} source=#{candidate.source}"
    )

    append(path, record)
  end

  defp append(path, record) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- DecisionLog.append(path, record) do
      :ok
    else
      {:error, reason} ->
        Logger.error("allowed_contributors audit_write_failed path=#{path} reason=#{inspect(reason)}")
        :ok
    end
  end

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
