defmodule Aiur.AgentRunner.ReworkHandoffGuard do
  @moduledoc false

  alias Aiur.AgentRunner.{ApprovedHandoff, ReworkFindings}
  alias Aiur.{Alerts, Issue, LocalTestEvidence, PrBodyLint, Tracker}
  alias Aiur.Events.GithubCIPoller.ApprovalCarry
  alias Aiur.GitHub.Client, as: GitHubClient
  alias Aiur.Orchestrator.ReworkGate

  @spec write(Issue.t(), String.t(), String.t(), Path.t() | nil, String.t() | nil, keyword(), fun()) ::
          {:ok, map()} | {:error, term()}
  def write(issue, issue_id, state, workspace, worker_host, opts, writer) do
    case blockers(issue, state, workspace, opts) do
      {:blocked, checks} ->
        message =
          "Cannot hand ticket #{issue.identifier} back to human review: PR head is unchanged and required checks are failing: #{Enum.join(checks, ", ")}. Address the Executor's latest rework comment or explain why it cannot be addressed."

        alert(issue, checks, message, workspace, worker_host, opts)
        {:error, {:no_op_rework, message}}

      {:refused, reason, message} ->
        {:error, {reason, message}}

      {:allow, findings} ->
        target = ApprovedHandoff.target_state(issue, state, opts)

        case writer.(issue_id, target) do
          :ok -> {:ok, report_checklist(issue, findings, opts, handoff_result(%{state: target, issue: issue_id}, state, target))}
          {:ok, result} -> {:ok, report_checklist(issue, findings, opts, handoff_result(result, state, target))}
          {:error, reason} -> {:error, reason}
          other -> {:error, other}
        end
    end
  end

  defp handoff_result(result, state, state), do: result

  defp handoff_result(result, requested, _target),
    do: Map.merge(result, %{requested_state: requested, reason: :approval_carries_to_pr_head})

  defp blockers(issue, state, workspace, opts) do
    with :allow <- rework_blockers(issue, state, opts),
         :allow <- evidence_blockers(issue, state, workspace, opts),
         :allow <- conflict_blockers(issue, state, opts) do
      findings_blockers(issue, state, workspace, opts)
    end
  end

  defp rework_blockers(%Issue{state: state} = issue, "human-review", opts) when state in ["rework", "agent:rework"] do
    ReworkGate.agent_handoff_blockers(issue.identifier, Keyword.get(opts, :rework_head_sha), opts)
  end

  defp rework_blockers(_issue, _state, _opts), do: :allow

  # #4611: a PR created after the first `aiur pre-pr` keeps stale Local tests evidence; refuse the handoff until it is refreshed.
  # #4937: with the worker's checkout at hand it runs the full `mix pr_body.check` lint (`Aiur.PrBodyLint`), so a body CI would reject is refused too.
  # An unreadable PR fails open here; the `pr body` CI check and the push backstop alert still cover it.
  @doc false
  @spec evidence_blockers(Issue.t(), String.t(), Path.t() | nil, keyword()) :: :allow | {:refused, atom(), String.t()}
  def evidence_blockers(issue, state, workspace, opts) when state in ["ci-wait", "human-review"] do
    with {:ok, pr} <- ReworkGate.open_pr(issue.identifier, opts),
         head when is_binary(head) <- ReworkGate.head_sha(pr),
         body when is_binary(body) <- pr["body"],
         {:error, reason} <- evidence_error(body, head, workspace, pr, opts) do
      {:refused, :stale_pr_body_evidence, evidence_refusal(issue, state, pr, head, reason)}
    else
      _ -> :allow
    end
  end

  def evidence_blockers(_issue, _state, _workspace, _opts), do: :allow

  defp evidence_refusal(issue, state, pr, head, {:stale_tested_head, tested_head}) do
    "Cannot hand ticket #{issue.identifier} to #{state}: PR ##{pr["number"]} body Tested head #{tested_head} does not match PR head #{head}. Rerun the touched tests at the PR head, then update the Tested head and Base evidence before handing off."
  end

  defp evidence_refusal(issue, state, pr, head, reason) do
    "Cannot hand ticket #{issue.identifier} to #{state}: PR ##{pr["number"]} body fails the PR body check (#{reason}). Fix the body. Run `aiur pre-pr` again after `gh pr create` so it writes `Tested head: #{head}` and `Base:`, then hand off."
  end

  defp evidence_error(body, head, workspace, pr, opts) do
    case LocalTestEvidence.parse(body) do
      {:ok, %{tested_head: tested_head}} ->
        validate_tested_head(body, tested_head, head, workspace, get_in(pr, ["base", "sha"]), pr, opts)

      _ ->
        lint_evidence_error(body, head, workspace)
    end
  end

  defp validate_tested_head(body, tested_head, head, workspace, base_sha, pr, opts) do
    cond do
      String.downcase(tested_head) == String.downcase(head) ->
        lint_evidence_error(body, head, workspace)

      identical_contribution_after_base_advance?(workspace, tested_head, head, base_sha, pr, opts) ->
        lint_evidence_error(body, tested_head, workspace)

      true ->
        {:error, {:stale_tested_head, tested_head}}
    end
  end

  defp identical_contribution_after_base_advance?(workspace, tested_head, head, base_sha, pr, opts)
       when is_binary(workspace) and is_binary(tested_head) and is_binary(head) and is_binary(base_sha) do
    classifier = Keyword.get(opts, :approval_carry_classifier)

    merge_only_advance?(workspace, tested_head, head) and
      classify_approval_carry(classifier, tested_head, head, pr["number"], opts) == :identical
  end

  defp identical_contribution_after_base_advance?(_workspace, _tested_head, _head, _base_sha, _pr, _opts), do: false

  defp classify_approval_carry(nil, tested_head, head, number, opts),
    do: ApprovalCarry.classify_contribution(tested_head, head, number, opts)

  defp classify_approval_carry(classifier, tested_head, head, number, opts) when is_function(classifier, 4),
    do: classifier.(tested_head, head, number, opts)

  defp merge_only_advance?(workspace, tested_head, head) do
    case System.cmd("git", ["-C", workspace, "rev-list", "--first-parent", "--no-merges", "#{tested_head}..#{head}"], stderr_to_stdout: true) do
      {"", 0} ->
        case System.cmd("git", ["-C", workspace, "merge-base", "--is-ancestor", tested_head, head], stderr_to_stdout: true) do
          {_, 0} -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  defp lint_evidence_error(body, head, workspace) do
    case pr_template(workspace) do
      {:ok, template} ->
        case PrBodyLint.errors(template, body, head: head) do
          [] -> :ok
          errors -> {:error, Enum.join(errors, "; ")}
        end

      _no_template ->
        with {:ok, evidence} <- LocalTestEvidence.parse(body), do: LocalTestEvidence.validate(evidence, "none", head)
    end
  end

  # A remote worker's checkout is not on this host, so the read fails and only the evidence is checked.
  defp pr_template(workspace) when is_binary(workspace), do: File.read(Path.join(workspace, ".github/pull_request_template.md"))
  defp pr_template(_workspace), do: :error

  # #4654: PRs were handed back while GitHub reported them CONFLICTING. The list read carries no mergeability,
  # so this reads the PR itself; an unreadable or still-computing state fails open.
  defp conflict_blockers(issue, state, opts) when state in ["ci-wait", "human-review"] do
    fetch = Keyword.get(opts, :pull_request_fetcher, &default_pull_request/1)

    with {:ok, %{"number" => number}} when is_integer(number) <- ReworkGate.open_pr(issue.identifier, opts),
         {:ok, %{"mergeable_state" => "dirty"}} <- fetch.(number) do
      {:refused, :pull_request_conflicting,
       "Cannot hand ticket #{issue.identifier} to #{state}: PR ##{number} conflicts with its base. Merge `origin/$AIUR_BASE_BRANCH`, resolve the conflicts, push, then hand off."}
    else
      _ -> :allow
    end
  end

  defp conflict_blockers(_issue, _state, _opts), do: :allow

  defp default_pull_request(number), do: if(ReworkGate.available?(), do: GitHubClient.fetch_open_pull_request(number), else: {:ok, nil})

  # #4654: a rework handback must answer every finding of the latest blocking review and carry commits made since it.
  @doc false
  @spec findings_blockers(Issue.t(), String.t(), Path.t() | nil, keyword()) :: {:allow, [ReworkFindings.finding()]} | {:refused, atom(), String.t()}
  def findings_blockers(%Issue{state: rework} = issue, state, workspace, opts)
      when state in ["ci-wait", "human-review"] and rework in ["rework", "agent:rework"] do
    review_blockers(ReworkFindings.fetch(issue.identifier, opts), issue, state, workspace, opts)
  end

  # #5746: workers move a rework ticket to `in-progress` before handing back, so an open review with findings
  # is checked in any state. Outside rework an unreadable review, or one with no numbered findings, fails open.
  def findings_blockers(%Issue{} = issue, state, workspace, opts) when state in ["ci-wait", "human-review"] do
    case ReworkFindings.fetch(issue.identifier, opts) do
      {:ok, %{review_head: review_head, findings: [_ | _]}} = fetched when is_binary(review_head) -> review_blockers(fetched, issue, state, workspace, opts)
      _no_open_review -> {:allow, []}
    end
  end

  def findings_blockers(_issue, _state, _workspace, _opts), do: {:allow, []}

  defp review_blockers(fetched, issue, state, workspace, opts) do
    case fetched do
      {:ok, %{number: number, head: head, review_head: nil}} ->
        no_review_comment_blocker(issue, state, workspace, head, number, opts)

      {:ok, %{review_head: review_head, head: head, findings: findings} = review} when is_binary(review_head) ->
        {commits, files} = ReworkFindings.branch_changes(workspace, review_head, head)
        # evidence_blockers already held the body to the current head, so an edit after the review is a body fix (#4944);
        # a finding with no file may be a body ask, so it is checked even alongside commits (#5746).
        body_edited? = (commits == [] or Enum.any?(findings, &is_nil(&1.file))) and ReworkFindings.body_edited_since?(review.number, review.review_at, opts)

        review_comment_blocker(%{
          issue: issue,
          state: state,
          workspace: workspace,
          head: head,
          review: review,
          findings: findings,
          commits: commits,
          files: files,
          body_edited?: body_edited?,
          opts: opts
        })

      {:error, reason} ->
        {:refused, :rework_findings_unaddressed, "Cannot hand ticket #{issue.identifier} back to #{state}: the latest review's findings could not be read (#{inspect(reason)}). Retry the handoff."}
    end
  end

  defp no_review_comment_blocker(issue, state, workspace, head, number, opts) do
    case ReworkFindings.latest_feedback_comment(number, nil, opts) do
      {:ok, comment} when is_map(comment) ->
        if ReworkFindings.change_request_comment?(comment_body(comment)),
          do: comment_handoff_blocker(issue, state, workspace, head, comment_body(comment), comment_timestamp(comment)),
          else: {:allow, []}

      {:ok, nil} ->
        {:allow, []}

      {:error, reason} ->
        unreadable_comments(issue, state, reason)
    end
  end

  defp review_comment_blocker(context) do
    %{issue: issue, state: state, workspace: workspace, head: head, review: review, opts: opts} = context

    case ReworkFindings.latest_feedback_comment(review.number, review.review_at, opts) do
      {:ok, comment} when is_map(comment) ->
        result =
          if ReworkFindings.change_request_comment?(comment_body(comment)),
            do: comment_handoff_blocker(issue, state, workspace, head, comment_body(comment), comment_timestamp(comment)),
            else: {:allow, []}

        continue_review_validation(result, context)

      {:ok, nil} ->
        validate_review_findings(context)

      {:error, reason} ->
        unreadable_comments(issue, state, reason)
    end
  end

  defp continue_review_validation({:allow, []}, context), do: validate_review_findings(context)

  defp continue_review_validation(refusal, _context), do: refusal

  defp validate_review_findings(context) do
    %{issue: issue, state: state, findings: findings, review: review, commits: commits, files: files, body_edited?: body_edited?, opts: opts} = context
    validate_review_findings(issue, state, findings, review, commits, files, body_edited?, opts)
  end

  defp unreadable_comments(issue, state, reason),
    do: {:refused, :rework_findings_unaddressed, "Cannot hand ticket #{issue.identifier} back to #{state}: trusted PR comments could not be checked (#{inspect(reason)}). Retry the handoff."}

  defp validate_review_findings(issue, state, findings, review, commits, files, body_edited?, opts) do
    case ReworkFindings.validate(findings, Keyword.get(opts, :review_findings), commits, files, body_edited?) do
      :allow ->
        {:allow, findings}

      {:blocked, reasons} ->
        {:refused, :rework_findings_unaddressed,
         "Cannot hand ticket #{issue.identifier} back to #{state}: #{Enum.join(reasons, "; ")}. Pass every finding in `review_findings` as `fixed` (with its commit) or `disputed` (with evidence); a PR-body-only fix counts once the body is edited after the review (#{review.review_at})."}
    end
  end

  defp comment_handoff_blocker(issue, state, workspace, head, body, commented_at) do
    if ReworkFindings.commit_after_comment?(workspace, head, commented_at) do
      {:allow, []}
    else
      {:refused, :rework_findings_unaddressed,
       "Cannot hand ticket #{issue.identifier} back to #{state}: the latest trusted PR comment requests changes, but no new non-merge commit has been pushed after it. Address the comment, push a commit, then hand off. Comment: #{String.slice(body, 0, 240)}"}
    end
  end

  defp comment_body(comment), do: Map.get(comment, "body") || Map.get(comment, :body) || ""

  defp comment_timestamp(comment),
    do: Map.get(comment, "updated_at") || Map.get(comment, :updated_at) || Map.get(comment, "created_at") || Map.get(comment, :created_at)

  # The re-review reads the worker's answers from this ticket comment; a failed post does not undo the handback.
  defp report_checklist(_issue, [], _opts, result), do: result

  defp report_checklist(issue, findings, opts, result) do
    comment = Keyword.get(opts, :checklist_commenter, &Tracker.create_comment/2)
    comment.(issue.id || issue.identifier, ReworkFindings.comment_body(findings, Keyword.get(opts, :review_findings)))
    result
  end

  defp alert(issue, checks, message, workspace, worker_host, opts) do
    case Keyword.get(opts, :no_op_rework_alert) do
      emit when is_function(emit, 3) ->
        emit.(issue, checks, message)

      _default ->
        Alerts.emit_custom("ticket.#{issue.identifier}.agent.attention.no_op_rework", message,
          issue: issue,
          workspace: workspace,
          worker_host: worker_host,
          reason: message,
          needs_attention: true,
          severity: "warning"
        )
    end
  end
end
