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
      {:error, {:github, kind, _} = reason} when kind in [:local_hold, :rate_limited] ->
        {:defer, reason}

      {:error, {:aiur, :locally_held, _} = reason} ->
        {:defer, reason}

      # Boot-time budget timeouts starve the ancestry read; it is missing evidence, not a verdict.
      {:error, :review_base_ancestry_unavailable = reason} ->
        {:defer, reason}

      {:error, {:github, :transport, %{reason: {:aiur, :locally_held, _}}} = reason} ->
        {:defer, reason}

      other ->
        other
    end
  end

  defp release(issue, opts) do
    opts = Keyword.put_new(opts, :ticket_identifier, issue.identifier)

    case target(issue, opts) do
      {:ok, slug} -> write_release(issue, lifecycle_state_name(slug, opts), opts)
      {:error, reason} -> {:defer, reason}
      {:defer, reason} -> {:defer, reason}
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

      {:error, {:stale_review_base, _detail} = reason} ->
        if DispatchPolicy.state_slug(target) == "human-review" do
          # A real conflict cannot be handed to review. Route the orphan to
          # rework so it gets an owner instead of deferring forever.
          write_release(issue, lifecycle_state_name("rework", opts), opts)
        else
          {:error, reason}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp target(issue, opts) do
    case Keyword.get(opts, :forced_target) do
      target when is_binary(target) -> {:ok, target}
      nil -> discover_target(issue, opts)
    end
  end

  defp discover_target(issue, opts) do
    fetch =
      Keyword.get(opts, :open_pr_fetcher, &Aiur.CodeHost.fetch_open_pull_request_for_branch/1)

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
      {:ok, :rework} -> current_head_review_target(pr, opts)
      {:skip, :no_unresolved_review_threads} -> current_head_review_target(pr, opts)
      {:error, _reason} = error -> error
    end
  end

  # An unresolved thread can belong to a review on an older head. Startup
  # recovery uses the same current-head review rule as agent handoff.
  defp current_head_review_target(pr, opts) do
    target = ReworkGate.post_agent_handoff_target(pr, "human-review", opts)

    preserve_newer_rework(target, pr, opts)
  end

  defp preserve_newer_rework(target, pr, opts) do
    if DispatchPolicy.state_slug(target) == "ci-wait" do
      rework_state_after_approval(target, pr, opts)
    else
      {:ok, target}
    end
  end

  defp rework_state_after_approval(target, pr, opts) do
    fetch_issue = Keyword.get(opts, :fetch_issue_states_fun, &Aiur.Tracker.fetch_issue_states_by_ids/1)
    identifier = Keyword.fetch!(opts, :ticket_identifier)

    case fetch_issue.([identifier]) do
      {:ok, [latest_issue]} -> rework_issue_target(target, latest_issue, pr, opts)
      _ -> {:defer, :ticket_state_unavailable}
    end
  end

  defp rework_issue_target(target, issue, pr, opts) do
    if DispatchPolicy.state_slug(issue.state) == "rework",
      do: rework_approval_target(target, issue, pr, opts),
      else: {:ok, target}
  end

  defp rework_approval_target(target, issue, pr, opts) do
    case current_head_approval(pr, opts) do
      {:ok, %{"submitted_at" => submitted_at}} ->
        if approval_after_rework?(submitted_at, issue.updated_at), do: {:ok, target}, else: {:ok, "rework"}

      {:ok, nil} ->
        {:ok, "rework"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp current_head_approval(pr, opts) do
    fetch_reviews = Keyword.get(opts, :reviews_fetcher, &Aiur.CodeHost.fetch_classified_pr_reviews/1)
    head = get_in(pr, ["head", "sha"])

    with true <- is_binary(head),
         {:ok, reviews} <- fetch_reviews.(Map.fetch!(pr, "number")) do
      case latest_head_approval(reviews, head) do
        %{"state" => "APPROVED"} = approval -> {:ok, approval}
        _ -> {:ok, nil}
      end
    else
      _ -> {:error, :approval_unavailable}
    end
  end

  defp latest_head_approval(reviews, head) do
    latest_by_reviewer =
      reviews
      |> Enum.filter(&(&1[:authoritative] == true and &1["state"] in ["APPROVED", "CHANGES_REQUESTED"]))
      |> Enum.group_by(&get_in(&1, ["user", "login"]))
      |> Enum.map(fn {_reviewer, submissions} -> Enum.max_by(submissions, &{&1["submitted_at"], &1["id"]}) end)
      |> Enum.filter(&(&1["commit_id"] == head))

    if Enum.any?(latest_by_reviewer, &(&1["state"] == "CHANGES_REQUESTED")) do
      nil
    else
      Enum.find(latest_by_reviewer, &(&1["state"] == "APPROVED"))
    end
  end

  defp approval_after_rework?(approval_at, %DateTime{} = rework_at) when is_binary(approval_at) do
    case DateTime.from_iso8601(approval_at) do
      {:ok, approval_time, _} -> DateTime.compare(approval_time, rework_at) == :gt
      _ -> false
    end
  end

  defp approval_after_rework?(_, _), do: false

  defp guarded_update(identifier, target, expected, writer),
    do: TicketTransition.write_state(identifier, target, writer: writer, expected_state: expected)

  defp lifecycle_state_name(slug, opts) do
    opts
    |> Keyword.get_lazy(:active_states, &Config.active_states/0)
    |> Enum.find(slug, &(DispatchPolicy.state_slug(&1) == slug))
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
