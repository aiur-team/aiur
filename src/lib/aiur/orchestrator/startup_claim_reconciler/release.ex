defmodule Aiur.Orchestrator.StartupClaimReconciler.Release do
  @moduledoc false

  alias Aiur.{Alerts, Config, Issue, Tracker}
  alias Aiur.GitHub.Client
  alias Aiur.Orchestrator.{DispatchPolicy, ReworkGate, TicketTransition}
  alias Aiur.Orchestrator.StartupClaimReconciler.Observation

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
      # Boot-time budget timeouts starve the ancestry read; it is missing evidence, not a verdict.
      {:error, :review_base_ancestry_unavailable = reason} -> {:defer, reason}
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
    writer = Keyword.get(opts, :writer, :startup_claim_reconciler)
    update = Keyword.get(opts, :update_issue_state_fun, &guarded_update(&1, &2, &3, writer))

    with true <- Observation.lease_free?(issue, opts),
         :ok <- update.(issue.identifier, target, issue.state) do
      comment(issue, target, Keyword.get(opts, :release_note, ""), opts)
      {:ok, target}
    else
      false ->
        {:defer, :workspace_owned}

      {:error, {:stale_review_base, %{pr_number: number}} = reason} ->
        if DispatchPolicy.state_slug(target) == "human-review",
          do: stale_review_base_release(issue, number, reason, opts),
          else: {:error, reason}

      {:error, _reason} = error ->
        error
    end
  end

  defp stale_review_base_release(issue, number, reason, opts) do
    approved_at_head = Keyword.get(opts, :approved_at_head_fetcher, &Client.pull_request_approved_at_head?/1)

    case approved_at_head.(number) do
      {:ok, true} ->
        {:defer, reason}

      {:ok, false} ->
        note = "No review asked for a change: this PR is behind its base and conflicts with or touches files changed there. Integrate the base, push, and hand it back."
        write_release(issue, lifecycle_state_name("rework", opts), Keyword.put(opts, :release_note, note))

      {:error, _approval_read_failed} ->
        {:defer, reason}
    end
  end

  defp target(issue, opts) do
    case Keyword.get(opts, :forced_target) do
      target when is_binary(target) -> {:ok, target}
      nil -> discover_target(issue, opts)
    end
  end

  defp discover_target(issue, opts) do
    fetch = Keyword.get(opts, :open_pr_fetcher, &Aiur.CodeHost.fetch_open_pull_request_for_branch/1)

    case fetch.(issue.identifier) do
      {:ok, nil} -> {:ok, Keyword.get(opts, :no_pr_target, "todo")}
      {:ok, pr} when is_map(pr) -> pr_target(pr, opts)
      {:error, _reason} = error -> error
    end
  end

  defp pr_target(pr, opts) do
    fetch = Keyword.get(opts, :pr_fetcher, &Client.fetch_open_pull_request/1)

    case fetch.(Map.fetch!(pr, "number")) do
      {:ok, %{"draft" => true}} -> {:ok, "rework"}
      {:ok, %{} = current} -> mergeability_target(current, opts)
      {:ok, nil} -> {:error, :pull_request_changed}
      {:ok, _unknown} -> {:error, :mergeability_unknown}
      {:error, _reason} = error -> error
    end
  end

  defp mergeability_target(%{"mergeable" => false, "number" => number} = pr, opts) do
    fetch = Keyword.get(opts, :mergeability_fetcher, &Client.pull_request_mergeability/1)

    case fetch.(number) do
      {:ok, "CONFLICTING"} -> {:ok, "rework"}
      {:ok, "MERGEABLE"} -> review_target(pr, opts)
      {:ok, "UNKNOWN"} -> {:error, :mergeability_unknown}
      {:error, _reason} = error -> error
    end
  end

  defp mergeability_target(%{"mergeable" => true} = pr, opts), do: review_target(pr, opts)
  defp mergeability_target(_pr, _opts), do: {:error, :mergeability_unknown}

  defp review_target(pr, opts) do
    case ReworkGate.open_pull_request_rework_verdict(pr, opts) do
      {:ok, :rework} ->
        case ReworkGate.approved_and_queued?(pr, opts) do
          {:ok, true} -> body_review_target(pr, opts)
          _not_approved_and_queued -> {:ok, "rework"}
        end

      {:skip, :no_unresolved_review_threads} ->
        body_review_target(pr, opts)

      {:error, _reason} = error ->
        error
    end
  end

  defp body_review_target(pr, opts) do
    {:ok, ReworkGate.post_agent_handoff_target(pr, "human-review", opts)}
  end

  defp guarded_update(identifier, target, expected, writer), do: TicketTransition.write_state(identifier, target, writer: writer, expected_state: expected)

  defp lifecycle_state_name(slug, opts) do
    opts |> Keyword.get_lazy(:active_states, &Config.active_states/0) |> Enum.find(slug, &(DispatchPolicy.state_slug(&1) == slug))
  end

  defp comment(issue, target, note, opts) do
    post = Keyword.get(opts, :create_comment_fun, &Tracker.create_comment/2)
    body = Keyword.get(opts, :release_body, &orphan_release_body/1).(target) <> note

    case post.(issue.identifier, body) do
      :ok -> :ok
      {:error, reason} -> comment_failed(issue, reason, opts)
    end
  end

  defp orphan_release_body(target),
    do: "Released orphaned in-progress claim to #{target}: no live worker or workspace lease owned this ticket throughout the recovery grace period."

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
