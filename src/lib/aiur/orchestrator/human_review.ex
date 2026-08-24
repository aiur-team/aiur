defmodule Aiur.Orchestrator.HumanReview do
  @moduledoc """
  Owns orchestrator HumanReview behavior.
  All functions execute inside the orchestrator GenServer process.
  """

  require Logger

  alias Aiur.GitHub.Client, as: GitHubClient
  alias Aiur.GitHub.Tracker, as: GitHubTracker
  alias Aiur.{Issue, Tracker}
  alias Aiur.Orchestrator.{AgentTeardown, DispatchPolicy, Reconciler, ReworkGate, State}
  alias Aiur.RunTelemetry.Lifecycle

  @doc false
  @spec human_review_state?(binary() | term()) :: boolean()
  def human_review_state?(state_name) when is_binary(state_name) do
    DispatchPolicy.normalize_issue_state(state_name) == "human-review"
  end

  def human_review_state?(_), do: false

  @doc false
  @spec maybe_deactivate_human_review_issue(State.t(), Issue.t()) :: State.t()
  def maybe_deactivate_human_review_issue(%State{} = state, %Issue{} = issue) do
    maybe_deactivate_human_review_issue(state, issue, [])
  end

  @doc false
  @spec maybe_deactivate_human_review_issue(State.t(), Issue.t(), keyword()) :: State.t()
  def maybe_deactivate_human_review_issue(%State{} = state, %Issue{} = issue, opts)
      when is_list(opts) do
    case verify_human_review_ready(issue) do
      :ok ->
        Lifecycle.record(
          issue.identifier,
          get_in(state.running, [issue.id, :telemetry_attempt_id]),
          :review_pause,
          :point,
          %{cause: :human_review_ready, outcome: :accepted}
        )

        AgentTeardown.deactivate_running_issue(state, issue.id)

      # The only reviewer verdict the gate can report is unaddressed
      # review-thread comments. `rework` means "work exists and was rejected"
      # (#2075), so only a verdict like this may move the ticket there.
      {:error, {:unverified_review_threads, _detail} = reason} ->
        reject_human_review_transition(state, issue, reason, opts)

      # Everything else the gate can return is an infrastructure or operational
      # fault, not a reviewer verdict: the open-PR search or viewer-login fetch
      # failed (rate limit, 5xx, timeout, auth), or the threads read could not
      # be classified. Reverting to `rework` on any of these strands a healthy
      # PR in a state whose rework turn has nothing to fix — the addressed
      # stale-CHANGES_REQUESTED loop #1756 keeps re-raising (#2400). Defer
      # instead: the ticket stays in `human-review` and the next poll
      # re-verifies, which is the same treatment a transient budget hold gets
      # (#2409).
      {:error, reason} ->
        defer_human_review_transition(state, issue, reason)
    end
  end

  defp verify_human_review_ready(%Issue{id: issue_id}) when is_binary(issue_id) do
    case Application.get_env(:aiur, :human_review_ready_verifier) do
      verifier when is_function(verifier, 1) ->
        verifier.(issue_id)

      _ ->
        verify_human_review_ready_with_tracker(issue_id)
    end
  end

  defp verify_human_review_ready(_issue), do: :ok

  defp defer_human_review_transition(%State{} = state, %Issue{} = issue, reason) do
    Logger.warning("human-review transition verification deferred: #{State.issue_context(issue)} reason=#{inspect(reason)}")

    state
  end

  defp verify_human_review_ready_with_tracker(issue_id) do
    if Tracker.adapter() == GitHubTracker do
      client = github_client_module()

      if function_exported?(client, :verify_human_review_ready, 1) do
        client.verify_human_review_ready(issue_id)
      else
        :ok
      end
    else
      :ok
    end
  end

  defp reject_human_review_transition(%State{} = state, %Issue{} = issue, reason, opts) do
    issue_key = issue.id || issue.identifier

    # A revert to `rework` is only meaningful against an open pull request: a
    # human-review ticket with no open PR has nothing a reviewer rejected, so
    # stamping `rework` would assert a verdict that never happened and strand
    # the ticket in a state nothing selects (#2075). With an open PR the revert
    # is the real "reviewer asked for changes" signal; without one the honest
    # restore is `todo` (make it dispatchable again, no verdict).
    case ReworkGate.verify_open_pr(issue_key, Keyword.get(opts, :rework_opts, [])) do
      :ok ->
        revert_human_review_state(state, issue, issue_key, "rework", "reverting to rework")

      {:skip, :no_open_pr} ->
        Logger.warning("human-review transition rejected for a ticket with no open PR; reverting to todo: #{State.issue_context(issue)} reason=#{inspect(reason)}")

        revert_human_review_state(state, issue, issue_key, "todo", "reverting to todo")

      {:error, pr_reason} ->
        Logger.warning("human-review rework revert deferred; open-PR check failed: #{State.issue_context(issue)} reason=#{inspect(pr_reason)}")

        state
    end
  end

  defp revert_human_review_state(%State{} = state, %Issue{} = issue, issue_key, target_state, log_label) do
    Logger.warning("human-review transition rejected; #{log_label}: #{State.issue_context(issue)}")

    case Tracker.update_issue_state(to_string(issue_key), target_state) do
      :ok ->
        Reconciler.maybe_reactivate_or_refresh(state, %{issue | state: target_state})

      {:error, update_reason} ->
        Logger.warning("human-review #{log_label} failed: #{State.issue_context(issue)} reason=#{inspect(update_reason)}")

        state
    end
  end

  defp github_client_module do
    Application.get_env(:aiur, :github_client_module, GitHubClient)
  end
end
