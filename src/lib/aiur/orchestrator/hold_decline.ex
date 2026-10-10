defmodule Aiur.Orchestrator.HoldDecline do
  @moduledoc """
  Classifies a failed dispatch-time GitHub read as a retry or an attention
  item (#4067).

  A read refused by the local budget guard is pacing, not a fault: the next
  poll retries it. Such a decline is recorded as `:github_budget_hold` at info
  and only becomes the attention decline (`fallback`) once
  `Aiur.GitHub.HoldPressure` has seen it repeat past the configured threshold.
  Every other failure keeps the fail-closed attention decline unchanged.
  """

  require Logger

  alias Aiur.GitHub.HoldPressure
  alias Aiur.Issue
  alias Aiur.Orchestrator.State

  @hold_reason :github_budget_hold

  @doc "The non-attention decline reason recorded for a transient hold."
  @spec hold_reason() :: :github_budget_hold
  def hold_reason, do: @hold_reason

  @doc """
  Logs the failure and returns the decline reason to record: `hold_reason/0`
  for a local hold still under the threshold, `fallback` otherwise.
  """
  @spec classify(Issue.t(), term(), atom(), keyword()) :: atom()
  def classify(%Issue{} = issue, failure, fallback, opts \\ []) when is_atom(fallback) and is_list(opts) do
    with true <- local_hold?(failure),
         :transient <- HoldPressure.dispatch_decline(issue.id, opts) do
      Logger.info("Dispatch deferred by a local GitHub budget hold; retrying next poll: #{State.issue_context(issue)} failure=#{inspect(failure)}")
      @hold_reason
    else
      _attention ->
        Logger.warning("Skipping dispatch (fail-closed, #{fallback}): #{State.issue_context(issue)} failure=#{inspect(failure)}")
        fallback
    end
  end

  defp local_hold?({:error, reason}), do: local_hold?(reason)
  defp local_hold?({:github, :local_hold, _detail}), do: true
  defp local_hold?({:aiur, :locally_held, _hold}), do: true
  defp local_hold?(_failure), do: false
end
