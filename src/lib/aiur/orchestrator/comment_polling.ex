defmodule Aiur.Orchestrator.CommentPolling do
  @moduledoc """
  GitHub firehose and comments poll drivers.
  All functions execute inside the orchestrator GenServer process.
  """

  require Logger

  alias Aiur.Config
  alias Aiur.Events.{GithubCommentsPoller, GithubFirehose}
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.CommentPolling.TargetSelection
  alias Aiur.Orchestrator.State

  @spec poll_github_firehose(State.t(), keyword()) :: State.t()
  def poll_github_firehose(%State{} = state, opts \\ []) do
    poll_opts =
      opts
      |> Keyword.put_new(:etag, state.events_etag)
      |> Keyword.put_new(:last_event_id, state.events_last_id)

    case GithubFirehose.poll(poll_opts) do
      {:ok, %{etag: etag, last_event_id: last_event_id, count: count} = result} ->
        if count > 0, do: Logger.debug("aiur_perf github_firehose published count=#{count}")

        state =
          state
          |> Orchestrator.note_github_connectivity_success(:firehose)
          |> Orchestrator.note_github_poll_interval(:firehose, Map.get(result, :poll_interval))

        %{state | events_etag: etag, events_last_id: last_event_id}

      {:error, reason} ->
        # Preserve cached etag so we retry as If-None-Match next tick; the
        # classified failure feeds the escalation policy so a sustained
        # DNS/auth break surfaces a loud operator blocker (#617).
        Orchestrator.note_github_connectivity_failure(state, :firehose, reason)
    end
  end

  @spec poll_github_comments(State.t(), keyword()) :: State.t()
  def poll_github_comments(%State{} = state, opts \\ []) do
    case Config.tracker_kind() do
      "github" -> do_poll_github_comments(state, opts)
      _ -> state
    end
  end

  defp do_poll_github_comments(%State{} = state, opts) do
    case TargetSelection.github_comment_poll_targets(state, opts) do
      {:ok, targets, human_review_targets, watch_targets} ->
        poll_github_comment_targets(state, targets, human_review_targets, watch_targets, opts)

      {:error, reason} ->
        Logger.warning("GithubCommentsPoller target refresh skipped; reason=#{inspect(reason)}")
        state
    end
  end

  defp poll_github_comment_targets(%State{} = state, [], _human_review_targets, _watch_targets, _opts),
    do: state

  defp poll_github_comment_targets(%State{} = state, targets, human_review_targets, watch_targets, opts)
       when is_list(targets) do
    poll_opts =
      opts
      |> Keyword.put_new(:since, state.github_comments_since)
      |> TargetSelection.put_open_pull_requests_by_target(human_review_targets)
      |> TargetSelection.put_open_pull_requests_by_target(watch_targets)

    case GithubCommentsPoller.poll(targets, poll_opts) do
      {:ok, %{since: since, count: count, errors: errors}} ->
        if count > 0,
          do: Logger.debug("aiur_perf github_comments_poller published count=#{count}")

        if errors != [] do
          Logger.warning("GithubCommentsPoller partial failures; reason=#{inspect(errors)}")
        end

        state =
          if all_comment_targets_failed?(targets, errors) do
            Orchestrator.note_github_connectivity_failure(state, :comments, comments_poll_classification(errors))
          else
            Orchestrator.note_github_connectivity_success(state, :comments)
          end

        %{
          state
          | github_comments_since: TargetSelection.merge_comment_cursors(state.github_comments_since, since),
            github_comment_issue_updated_at:
              TargetSelection.remember_polled_human_review_targets(
                state.github_comment_issue_updated_at,
                human_review_targets,
                errors
              )
        }
    end
  end

  # The comments poller aggregates per-target failures as
  # [{target, {scope, taxonomy}}]; pull the first classified GitHub error
  # out so the escalation policy sees the underlying connectivity class.
  defp comments_poll_classification([{_target, {_scope, taxonomy}} | _]), do: taxonomy
  defp comments_poll_classification(reason), do: reason

  defp all_comment_targets_failed?(_targets, []), do: false

  defp all_comment_targets_failed?(targets, errors) do
    failed_targets =
      errors
      |> Enum.map(fn {target, _reason} -> target end)
      |> MapSet.new()

    targets
    |> MapSet.new()
    |> MapSet.subset?(failed_targets)
  end
end
