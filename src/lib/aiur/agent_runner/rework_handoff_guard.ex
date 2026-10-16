defmodule Aiur.AgentRunner.ReworkHandoffGuard do
  @moduledoc false

  alias Aiur.AgentRunner.ReworkChecklist
  alias Aiur.{Alerts, Issue, LocalTestEvidence}
  alias Aiur.GitHub.Client, as: GitHubClient
  alias Aiur.Orchestrator.ReworkGate

  @spec write(
          Issue.t(),
          String.t(),
          String.t(),
          Path.t() | nil,
          String.t() | nil,
          keyword(),
          fun()
        ) ::
          {:ok, map()} | {:error, term()}
  def write(issue, issue_id, state, workspace, worker_host, opts, writer) do
    case blockers(issue, state, opts) do
      {:blocked, checks} ->
        message =
          "Cannot hand ticket #{issue.identifier} back to #{state}: #{Enum.join(checks, "; ")}. Address every finding and correct the PR state before handoff."

        alert(issue, checks, message, workspace, worker_host, opts)
        {:error, {:rework_handoff_blocked, message}}

      {:stale_evidence, message} ->
        {:error, {:stale_pr_body_evidence, message}}

      :allow ->
        case writer.(issue_id, state) do
          :ok -> {:ok, %{state: state, issue: issue_id}}
          {:ok, result} -> {:ok, result}
          {:error, reason} -> {:error, reason}
          other -> {:error, other}
        end
    end
  end

  defp blockers(issue, state, opts) do
    with :allow <- rework_checklist_blockers(issue, state, opts),
         :allow <- pull_request_status_blockers(issue, state, opts),
         :allow <- rework_blockers(issue, state, opts) do
      evidence_blockers(issue, state, opts)
    end
  end

  defp rework_checklist_blockers(%Issue{state: state} = issue, target, opts)
       when target in ["human-review", "ci-wait"] and state in ["rework", "agent:rework"] do
    fetcher =
      Keyword.get(opts, :review_checklist_fetcher, fn identifier ->
        default_review_checklist(identifier, opts)
      end)

    case fetcher.(issue.identifier) do
      {:ok, findings} when is_list(findings) -> validate_checklist(findings, opts)
      {:error, reason} -> {:blocked, ["review findings could not be loaded: #{inspect(reason)}"]}
    end
  end

  defp rework_checklist_blockers(_issue, _state, _opts), do: :allow

  defp default_review_checklist(identifier, opts) do
    with {:ok, pr} <- ReworkGate.open_pr(identifier, opts),
         number when is_integer(number) <- pr["number"],
         {:ok, findings} <- Aiur.CodeHost.fetch_unaddressed_pr_review_thread_comments(number) do
      {:ok, findings}
    else
      _unknown -> {:error, :review_findings_unavailable}
    end
  end

  defp validate_checklist(findings, opts) do
    ReworkChecklist.validate(
      findings,
      Keyword.get(opts, :rework_checklist),
      Keyword.get(opts, :rework_head_sha),
      Keyword.get(opts, :rework_commits_since_review, []),
      Keyword.get(opts, :rework_touched_files, [])
    )
  end

  defp pull_request_status_blockers(%Issue{state: state} = issue, target, opts)
       when target in ["human-review", "ci-wait"] and state in ["rework", "agent:rework"] do
    case ReworkGate.open_pr(issue.identifier, opts) do
      {:ok, pr} -> check_pull_request_status(pr, opts)
      {:error, reason} -> {:blocked, ["pull request could not be found: #{inspect(reason)}"]}
      _unknown -> {:blocked, ["pull request could not be found"]}
    end
  end

  defp pull_request_status_blockers(_issue, _state, _opts), do: :allow

  defp check_pull_request_status(pr, opts) do
    fetcher = Keyword.get(opts, :pull_request_status_fetcher, &default_pull_request_status/1)

    case fetcher.(pr) do
      {:ok, %{draft?: true}} ->
        {:blocked, ["pull request is still a draft"]}

      {:ok, %{mergeable: "CONFLICTING"}} ->
        {:blocked, ["pull request conflicts with its base"]}

      {:ok, _status} ->
        :allow

      {:error, reason} ->
        {:blocked, ["pull request state could not be verified: #{inspect(reason)}"]}

      _unknown ->
        {:blocked, ["pull request state could not be verified"]}
    end
  end

  defp default_pull_request_status(%{"number" => number}) when is_integer(number) do
    case GitHubClient.fetch_open_pull_request(number) do
      {:ok, %{"isDraft" => draft, "mergeable" => mergeable}}
      when is_boolean(draft) and is_binary(mergeable) ->
        {:ok, %{draft?: draft, mergeable: mergeable}}

      {:ok, _partial} ->
        {:error, :pull_request_status_incomplete}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp default_pull_request_status(_pr), do: {:error, :pull_request_number_missing}

  defp workspace_diff_evidence(workspace, review_head)
       when is_binary(workspace) and is_binary(review_head) do
    with {commits_output, 0} <-
           System.cmd("git", ["-C", workspace, "log", "--format=%H", "#{review_head}..HEAD"], stderr_to_stdout: true),
         {paths_output, 0} <-
           System.cmd("git", ["-C", workspace, "diff", "--name-only", "#{review_head}...HEAD"], stderr_to_stdout: true) do
      [
        rework_commits_since_review: String.split(commits_output, "\n", trim: true),
        rework_touched_files: String.split(paths_output, "\n", trim: true)
      ]
    else
      _git_unavailable -> [rework_commits_since_review: [], rework_touched_files: []]
    end
  end

  defp workspace_diff_evidence(_workspace, _review_head),
    do: [rework_commits_since_review: [], rework_touched_files: []]

  @doc false
  @spec handoff_blockers(Issue.t(), String.t(), Path.t() | nil, String.t() | nil, keyword()) ::
          :allow | {:blocked, [String.t()]} | {:error, term()}
  def handoff_blockers(issue, target, workspace, _worker_host, opts) do
    evidence =
      case workspace_diff_evidence(workspace, Keyword.get(opts, :rework_head_sha)) do
        [rework_commits_since_review: [], rework_touched_files: []] ->
          fallback_diff_evidence(issue, opts)

        observed ->
          observed
      end

    options = Keyword.merge(opts, evidence)

    checks = blockers(issue, target, options)

    case checks do
      :allow -> :allow
      {:blocked, reasons} -> {:blocked, reasons}
      {:stale_evidence, reason} -> {:error, {:stale_pr_body_evidence, reason}}
    end
  end

  defp fallback_diff_evidence(issue, opts) do
    explicit = Keyword.take(opts, [:rework_commits_since_review, :rework_touched_files])

    if Keyword.has_key?(explicit, :rework_commits_since_review) do
      explicit
    else
      pr_head_diff_evidence(issue, opts, explicit)
    end
  end

  defp pr_head_diff_evidence(issue, opts, explicit) do
    case ReworkGate.open_pr(issue.identifier, opts) do
      {:ok, pr} ->
        head = ReworkGate.head_sha(pr)
        review_head = Keyword.get(opts, :rework_head_sha)
        commits = if is_binary(head) and head != review_head, do: [head], else: []
        Keyword.merge([rework_commits_since_review: commits], explicit)

      _missing_pr ->
        explicit
    end
  end

  defp rework_blockers(%Issue{state: state} = issue, target, opts)
       when target == "human-review" and state in ["rework", "agent:rework"] do
    case ReworkGate.agent_handoff_blockers(
           issue.identifier,
           Keyword.get(opts, :rework_head_sha),
           opts
         ) do
      {:blocked, checks} ->
        alert(
          issue,
          checks,
          "Cannot hand ticket #{issue.identifier} back to human review: PR head is unchanged and required checks are failing: #{Enum.join(checks, ", ")}. Address the Executor's latest rework comment or explain why it cannot be addressed.",
          Keyword.get(opts, :workspace),
          Keyword.get(opts, :worker_host),
          opts
        )

        {:blocked, checks}

      :allow ->
        :allow
    end
  end

  defp rework_blockers(_issue, _target, _opts), do: :allow

  # #4611: a PR created after the first `aiur pre-pr` keeps stale Local tests evidence; refuse the handoff until it is refreshed.
  # An unreadable PR fails open here; the `pr body` CI check and the push backstop alert still cover it.
  defp evidence_blockers(issue, state, opts) when state in ["ci-wait", "human-review"] do
    with {:ok, pr} <- ReworkGate.open_pr(issue.identifier, opts),
         head when is_binary(head) <- ReworkGate.head_sha(pr),
         body when is_binary(body) <- pr["body"],
         {:error, reason} <- evidence_error(body, head) do
      {:stale_evidence,
       "Cannot hand ticket #{issue.identifier} to #{state}: PR ##{pr["number"]} body is wrong (#{reason}). Run `aiur pre-pr` again after `gh pr create` so it writes `Tested head: #{head}` and `Base:`, then hand off."}
    else
      _ -> :allow
    end
  end

  defp evidence_blockers(_issue, _state, _opts), do: :allow

  defp evidence_error(body, head) do
    with {:ok, evidence} <- LocalTestEvidence.parse(body),
         do: LocalTestEvidence.validate(evidence, "none", head)
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
