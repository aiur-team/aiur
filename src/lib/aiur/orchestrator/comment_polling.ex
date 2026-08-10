defmodule Aiur.Orchestrator.CommentPolling do
  @moduledoc """
  GitHub firehose and comments poll drivers.
  All functions execute inside the orchestrator GenServer process.
  """

  require Logger

  alias Aiur.{Alerts, Config, SweepWatermarkStore}
  alias Aiur.Events.{GithubCommentsPoller, GithubFirehose}
  alias Aiur.GitHub.CommentPollBatch
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.CommentPolling.TargetSelection
  alias Aiur.Orchestrator.State

  @recent_merge_persistence_retry_limit 3

  @spec poll_github_firehose(State.t(), keyword()) :: State.t()
  def poll_github_firehose(%State{} = state, opts \\ []) do
    swept_at = Keyword.get(opts, :now) || DateTime.utc_now()

    poll_opts =
      opts
      |> Keyword.put_new(:etag, state.events_etag)
      |> Keyword.put_new(:last_event_id, state.events_last_id)
      |> put_sweep_cutoff(state)

    case GithubFirehose.poll(poll_opts) do
      {:ok, %{etag: etag, last_event_id: last_event_id, count: count} = result} ->
        if count > 0, do: Logger.debug("aiur_perf github_firehose published count=#{count}")

        state =
          state
          |> Orchestrator.note_github_connectivity_success(:firehose)
          |> Orchestrator.note_github_poll_interval(:firehose, Map.get(result, :poll_interval))
          |> note_recent_merge_persistence_success(Map.get(result, :recent_merge_persistence))

        state = %{state | events_etag: etag, events_last_id: last_event_id, sweep_observed_at: swept_at}

        persist_sweep_watermark(state, opts)

      {:error, {:recent_merge_persistence, reason, cursor}} ->
        note_recent_merge_persistence_failure(state, reason, cursor, opts)

      {:error, reason} ->
        # Preserve cached etag so we retry as If-None-Match next tick; the
        # classified failure feeds the escalation policy so a sustained
        # DNS/auth break surfaces a loud Executor blocker (#617).
        Orchestrator.note_github_connectivity_failure(state, :firehose, reason)
    end
  end

  # The firehose drops anything created before this boot so a restart cannot
  # replay a day of Events API history into live agents. That drop is also what
  # makes an event delivered while the daemon was down unrecoverable, so when a
  # prior sweep is on record we hand the firehose that sweep time instead: the
  # window becomes "since we last actually looked" rather than "since boot".
  # With no prior sweep on record, the boot cutoff stands unchanged.
  defp put_sweep_cutoff(poll_opts, %State{sweep_observed_at: %DateTime{} = observed_at}) do
    Keyword.put_new(poll_opts, :boot_time, DateTime.to_unix(observed_at))
  end

  defp put_sweep_cutoff(poll_opts, %State{}), do: poll_opts

  # Persisting after the publish keeps the cursor honest under a crash: a sweep
  # that published events but died before writing re-reads that window on the
  # next boot and republishes into an empty dedup table, which is recoverable.
  # Recording the cursor first and then dying would lose the events outright.
  defp persist_sweep_watermark(%State{} = state, opts) do
    _ =
      SweepWatermarkStore.save(
        %{
          events_last_id: state.events_last_id,
          comment_cursors: comment_cursors(state),
          pr_review_seen_at: state.pr_review_seen_at,
          observed_at: state.sweep_observed_at
        },
        opts
      )

    state
  end

  # `github_comments_since` is a per-target cursor map in steady state, but the
  # field also accepts a single legacy binary cursor. Only the per-target shape
  # is durable; a bare binary is not attributable to a target on restore.
  defp comment_cursors(%State{github_comments_since: %{} = cursors}), do: cursors
  defp comment_cursors(%State{}), do: %{}

  defp note_recent_merge_persistence_success(state, :ok) do
    Orchestrator.note_github_connectivity_success(state, :recent_merge_store)
  end

  defp note_recent_merge_persistence_success(state, _status), do: state

  defp note_recent_merge_persistence_failure(state, reason, cursor, opts) do
    failures = recent_merge_persistence_failure_count(state) + 1
    retry_limit = recent_merge_persistence_retry_limit(opts)
    advance? = failures >= retry_limit

    Logger.warning("GithubFirehose local outcome persistence failed; attempt=#{failures} advance=#{advance?} reason=#{inspect(reason)}")

    state =
      state
      |> Orchestrator.note_github_connectivity_success(:firehose)
      |> Orchestrator.note_github_poll_interval(:firehose, Map.get(cursor, :poll_interval))
      |> Orchestrator.note_github_connectivity_failure(:recent_merge_store, {:recent_merge_persistence, reason})
      |> maybe_alert_recent_merge_persistence(reason, retry_limit, opts)

    if advance? do
      # The sweep read and published successfully; only the local outcome
      # journal failed. Advance and persist the cursor, but leave the sweep
      # timestamp alone so the next window stays wide rather than narrowing on
      # the strength of a partially-failed cycle.
      state = %{
        state
        | events_etag: Map.get(cursor, :etag),
          events_last_id: Map.get(cursor, :last_event_id)
      }

      persist_sweep_watermark(state, opts)
    else
      state
    end
  end

  defp recent_merge_persistence_failure_count(state) do
    case Map.get(state.github_connectivity, :recent_merge_store) do
      {_classification, count} when is_integer(count) and count > 0 -> count
      _other -> 0
    end
  end

  defp recent_merge_persistence_retry_limit(opts) do
    case Keyword.get(opts, :recent_merge_persistence_retry_limit, @recent_merge_persistence_retry_limit) do
      value when is_integer(value) and value > 0 -> value
      _other -> @recent_merge_persistence_retry_limit
    end
  end

  defp maybe_alert_recent_merge_persistence(state, reason, limit, opts) do
    if recent_merge_persistence_failure_count(state) == limit do
      emit_recent_merge_persistence_alert(state, reason, opts)
    else
      state
    end
  end

  defp emit_recent_merge_persistence_alert(state, reason, opts) do
    failures = recent_merge_persistence_failure_count(state)

    message =
      "Recent repository merge audit remains read-only or unwritable after " <>
        "#{failures} attempts (#{inspect(reason)}). " <>
        "GitHub event delivery is continuing without durable outcome records until storage recovers."

    alert_fun = Keyword.get(opts, :recent_merge_alert_fun, &Alerts.emit_custom/3)

    _ =
      alert_fun.("recent_merge_store.persistence_failed", message,
        reason: message,
        needs_attention: true,
        severity: "warning"
      )

    state
  rescue
    error ->
      Logger.warning("GithubFirehose local outcome persistence alert failed; reason=#{Exception.message(error)}")
      state
  catch
    kind, reason ->
      Logger.warning("GithubFirehose local outcome persistence alert failed; reason=#{inspect({kind, reason})}")
      state
  end

  @spec poll_github_comments(State.t(), keyword()) :: State.t()
  def poll_github_comments(%State{} = state, opts \\ []) do
    case Config.tracker_kind() do
      # Comment polling always runs at the configured cadence. #1384 scoped a
      # widen-on-quiet backoff, but it is deliberately not implemented: a global
      # quiet gate is inert whenever any agent is running (the case the rate
      # incident is about) and a per-target one would delay a new ticket's first
      # comment wake, which the ticket lists as a non-goal. The steady-state
      # saving comes from 304s and the GraphQL batch, not from skipping cycles.
      "github" ->
        do_poll_github_comments(state, opts)

      _ ->
        state
    end
  end

  defp do_poll_github_comments(%State{} = state, opts) do
    case TargetSelection.github_comment_poll_targets_with_cache(state, opts) do
      {:ok, targets, human_review_targets, watch_targets, cache} ->
        state = put_in(state.ci_lifecycle.poll_cache[:issue_list_cache], cache)
        poll_github_comment_targets(state, targets, human_review_targets, watch_targets, opts)

      {:error, reason} ->
        Logger.warning("GithubCommentsPoller target refresh skipped; reason=#{inspect(reason)}")
        state
    end
  end

  defp poll_github_comment_targets(%State{} = state, [], _human_review_targets, _watch_targets, _opts), do: state

  defp poll_github_comment_targets(%State{} = state, targets, human_review_targets, watch_targets, opts)
       when is_list(targets) do
    review_submission_targets = MapSet.new(human_review_targets, & &1.target)

    poll_opts =
      opts
      |> Keyword.put_new(:since, state.github_comments_since)
      |> Keyword.put_new(:etags, state.github_comment_etags)
      |> TargetSelection.put_open_pull_requests_by_target(human_review_targets)
      |> TargetSelection.put_open_pull_requests_by_target(watch_targets)
      |> Keyword.put_new(:titles_by_target, running_titles_by_target(state))
      |> Keyword.put(:review_submission_targets, review_submission_targets)
      |> Keyword.put(:pr_review_seen_at, state.pr_review_seen_at)

    poll_opts = put_comment_batch(poll_opts, targets)

    case GithubCommentsPoller.poll(targets, poll_opts) do
      {:ok, %{since: since, etags: etags, count: count, errors: errors, pr_review_seen_at: new_review_seen_at}} ->
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

        state = %{
          state
          | github_comments_since: TargetSelection.merge_comment_cursors(state.github_comments_since, since),
            github_comment_etags: Map.merge(state.github_comment_etags, etags),
            github_comment_issue_updated_at:
              TargetSelection.remember_polled_human_review_targets(
                state.github_comment_issue_updated_at,
                human_review_targets,
                errors
              ),
            pr_review_seen_at: Map.merge(state.pr_review_seen_at, new_review_seen_at)
        }

        # Comment and review-submission cursors are per target, so restoring
        # them is on its own enough to reopen the window a restart would
        # otherwise close on #1427's review poller and on comment wakes.
        persist_sweep_watermark(state, opts)
    end
  end

  # GitHub issues carry no branch name, so the comment batch derives each
  # running ticket's generated `aiur/<id>-<slug>` branch from its title. Without
  # this every target without an already-known PR guesses the legacy
  # `aiur/<id>` branch, misses, and falls back to the full REST fan-out.
  defp running_titles_by_target(%State{} = state) do
    state.running
    |> Map.values()
    |> Enum.reduce(%{}, fn entry, acc ->
      with identifier when is_binary(identifier) and identifier != "" <- Map.get(entry, :identifier),
           %{title: title} when is_binary(title) and title != "" <- Map.get(entry, :issue) do
        Map.put(acc, to_string(identifier), title)
      else
        _other -> acc
      end
    end)
  end

  defp put_comment_batch(opts, targets) do
    fetcher = Keyword.get(opts, :comment_batch_fetcher, &CommentPollBatch.fetch/2)

    case fetcher.(targets, opts) do
      {:ok, batch} when is_map(batch) ->
        Keyword.put(opts, :comment_batch, batch)

      {:error, reason} ->
        Logger.warning("Github comment GraphQL batch failed; falling back to conditional REST reads reason=#{inspect(reason)}")
        opts

      other ->
        Logger.warning("Github comment GraphQL batch returned unexpected value; falling back to conditional REST reads value=#{inspect(other)}")
        opts
    end
  rescue
    exception ->
      # The fallback keeps polling correct, but an exception here is a bug in
      # the batch itself, not an expected condition: log it at :error with the
      # stacktrace so it cannot hide as an indefinitely silent REST fallback.
      Logger.error(
        "Github comment GraphQL batch raised; falling back to conditional REST reads error=" <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      opts
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
