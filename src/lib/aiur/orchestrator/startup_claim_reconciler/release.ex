defmodule Aiur.Orchestrator.StartupClaimReconciler.Release do
  @moduledoc false

  alias Aiur.{Alerts, Config, Issue, Tracker}
  alias Aiur.GitHub.Client, as: GitHubClient
  alias Aiur.Orchestrator.{DispatchPolicy, ReworkGate, TicketTransition}
  alias Aiur.Orchestrator.StartupClaimReconciler.Observation

  # Without this the rework agent finds no review to answer and no-ops (#3846).
  @stale_base_note " No review asked for a change: the pull request is behind its base branch and conflicts with or touches files changed there. Integrate the base, push, and hand it back for review."

  @spec run(Issue.t(), keyword()) :: {:ok, String.t()} | {:error, term()} | {:defer, term()}
  def run(issue, opts) do
    result =
      case Keyword.fetch(opts, :release_fun) do
        {:ok, release} -> release.(issue, opts)
        :error -> release(issue, opts)
      end

    case result do
      {:error, {:github, kind, _} = reason} when kind in [:local_hold, :rate_limited] -> {:defer, reason}
      {:error, {:aiur, :locally_held, _} = reason} -> {:defer, reason}
      {:error, {:github, :transport, %{reason: {:aiur, :locally_held, _}}} = reason} -> {:defer, reason}
      other -> other
    end
  end

  defp release(issue, opts) do
    case target(issue, opts) do
      {:ok, slug} -> write_release(issue, lifecycle_state_name(slug, opts), opts)
      {:error, reason} -> {:defer, reason}
    end
  end

  defp write_release(issue, target, opts) do
    update = Keyword.get(opts, :update_issue_state_fun, &guarded_update/3)

    with true <- Observation.lease_free?(issue, opts),
         :ok <- update.(issue.identifier, target, issue.state) do
      comment(issue, target, Keyword.get(opts, :release_note, ""), opts)
      {:ok, target}
    else
      false ->
        {:defer, :workspace_owned}

      {:error, {:stale_review_base, _}} = error ->
        if DispatchPolicy.state_slug(target) == "human-review",
          do: write_release(issue, lifecycle_state_name("rework", opts), Keyword.put(opts, :release_note, @stale_base_note)),
          else: error

      {:error, _reason} = error ->
        error
    end
  end

  defp target(issue, opts) do
    fetch = Keyword.get(opts, :open_pr_fetcher, &Aiur.CodeHost.fetch_open_pull_request_for_branch/1)

    case fetch.(issue.identifier) do
      {:ok, nil} -> {:ok, "todo"}
      {:ok, pr} when is_map(pr) -> pr_target(pr, opts)
      {:error, _reason} = error -> error
    end
  end

  defp pr_target(pr, opts) do
    fetch = Keyword.get(opts, :pr_fetcher, &GitHubClient.fetch_open_pull_request/1)

    case fetch.(Map.fetch!(pr, "number")) do
      {:ok, %{"mergeable" => false}} -> {:ok, "rework"}
      {:ok, %{"mergeable" => true} = current} -> review_target(current, opts)
      {:ok, nil} -> {:error, :pull_request_changed}
      {:ok, _unknown} -> {:error, :mergeability_unknown}
      {:error, _reason} = error -> error
    end
  end

  defp review_target(pr, opts) do
    case ReworkGate.open_pull_request_rework_verdict(pr, opts) do
      {:ok, :rework} -> {:ok, "rework"}
      {:skip, :no_unresolved_review_threads} -> body_review_target(pr, opts)
      {:error, _reason} = error -> error
    end
  end

  defp body_review_target(pr, opts) do
    fetch = Keyword.get(opts, :reviews_fetcher, &Aiur.CodeHost.fetch_classified_pr_reviews/1)

    with {:ok, reviews} <- fetch.(Map.fetch!(pr, "number")) do
      # Only a trusted verdict on this head is current; old CHANGES_REQUESTED is sticky.
      head = get_in(pr, ["head", "sha"])
      findings? = is_binary(head) and reviews |> ReworkGate.blocking_reviews() |> Enum.any?(&(&1["commit_id"] == head))
      {:ok, if(findings?, do: "rework", else: "human-review")}
    end
  end

  defp guarded_update(identifier, target, expected), do: TicketTransition.write_state(identifier, target, writer: :startup_claim_reconciler, expected_state: expected)

  defp lifecycle_state_name(slug, opts) do
    opts |> Keyword.get_lazy(:active_states, &Config.active_states/0) |> Enum.find(slug, &(DispatchPolicy.state_slug(&1) == slug))
  end

  defp comment(issue, target, note, opts) do
    post = Keyword.get(opts, :create_comment_fun, &Tracker.create_comment/2)
    body = "Released orphaned in-progress claim to #{target}: no live worker or workspace lease owned this ticket throughout the recovery grace period." <> note

    case post.(issue.identifier, body) do
      :ok -> :ok
      {:error, reason} -> comment_failed(issue, reason, opts)
    end
  end

  defp comment_failed(issue, reason, opts) do
    emit = Keyword.get(opts, :emit_alert_fun, &Alerts.emit_system/2)

    emit.("ticket.#{issue.identifier}.agent.attention.orphan_release_comment_failed",
      issue: issue,
      message: "Orphaned claim released, but its recovery comment failed.",
      reason: inspect(reason),
      needs_attention: true,
      central: true,
      durable: true
    )
  end
end
