defmodule Aiur.GitHub.Listeners.Comments.Poll do
  @moduledoc false
  require Logger
  alias Aiur.Events.GithubCommentsPoller
  alias Aiur.GitHub.CommentPollBatch
  alias Aiur.GitHub.Listeners.Comments.{Cursor, Input, OwnedPoll, TargetSelection}
  @comment_poll_setup_timeout_ms 300_000

  @spec setup_timeout_ms(keyword()) :: pos_integer()
  def setup_timeout_ms(opts) do
    case Keyword.get(opts, :setup_timeout, @comment_poll_setup_timeout_ms) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _other -> @comment_poll_setup_timeout_ms
    end
  end

  # The I/O half. Runs on whichever process the caller chose — never touches the
  # state it was handed, so its result can be folded into a newer one.
  @spec run(Cursor.t(), Input.t(), keyword()) :: term()
  def run(%Cursor{} = state, %Input{} = input, opts) do
    case run_comment_poll_setup(state, input, opts) do
      {:ok, cache, human_review_targets, targets, poll_opts} ->
        {:ok, cache, human_review_targets, poll_prepared_targets(targets, poll_opts)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Discovery, PR freshness, authorization timelines, pagination, and the
  # GraphQL batch can each issue a variable number of sequential requests. A
  # guessed request count cannot prove an outer lifetime bound, so setup owns
  # one explicit wall-clock budget instead. The worker is linked into the poll
  # tree, and timeout reaps its request descendants before returning.
  defp run_comment_poll_setup(%Cursor{} = state, input, opts) do
    parent = self()
    result_ref = make_ref()
    timeout_ms = setup_timeout_ms(opts)
    previous_trap_exit = Process.flag(:trap_exit, true)

    {worker, worker_ref} =
      :erlang.spawn_opt(
        fn -> send(parent, {__MODULE__, result_ref, prepare_comment_poll(state, input, opts)}) end,
        [:link, :monitor]
      )

    try do
      await_comment_poll_setup(worker, worker_ref, result_ref, timeout_ms)
    after
      Process.unlink(worker)
      flush_link_exit(worker)
      Process.flag(:trap_exit, previous_trap_exit)
    end
  end

  defp await_comment_poll_setup(worker, worker_ref, result_ref, timeout_ms) do
    receive do
      {__MODULE__, ^result_ref, result} ->
        OwnedPoll.await_process_down(worker, worker_ref)
        result

      {:DOWN, ^worker_ref, :process, ^worker, reason} ->
        exit({:comment_poll_setup_exit, reason})
    after
      timeout_ms ->
        Logger.warning("GithubCommentsPoller setup exceeded its #{timeout_ms}ms phase deadline and was abandoned")
        OwnedPoll.reap_process_tree(worker, worker_ref)
        flush_setup_result(result_ref)
        {:error, :setup_deadline_exceeded}
    end
  end

  defp flush_setup_result(result_ref) do
    receive do
      {__MODULE__, ^result_ref, _result} -> :ok
    after
      0 -> :ok
    end
  end

  defp flush_link_exit(worker) do
    receive do
      {:EXIT, ^worker, _reason} -> :ok
    after
      0 -> :ok
    end
  end

  defp prepare_comment_poll(%Cursor{} = state, input, opts) do
    case TargetSelection.github_comment_poll_targets_with_cache(state, input, opts) do
      {:ok, targets, human_review_targets, watch_targets, cache} ->
        poll_opts = prepare_comment_poll_opts(state, input, targets, human_review_targets, watch_targets, opts)
        {:ok, cache, human_review_targets, targets, poll_opts}

      {:error, _reason} = error ->
        error
    end
  end

  @spec apply(Cursor.t(), term()) :: {Cursor.t(), map()}
  def apply(%Cursor{} = cursor, {:ok, cache, targets, result}) do
    fold(%{cursor | issue_list_cache: cache}, targets, result)
  end

  def apply(%Cursor{} = cursor, {:error, reason}) do
    Logger.warning("GithubCommentsPoller target refresh skipped; reason=#{inspect(reason)}")
    {cursor, %{}}
  end

  def apply(%Cursor{} = cursor, _unrecognised), do: {cursor, %{}}

  defp fold(cursor, _targets, :no_targets), do: {cursor, %{}}

  defp fold(cursor, human_review_targets, {targets, {:ok, %{since: since, etags: etags, count: count, errors: errors, pr_review_seen_at: seen} = polled}}) do
    if count > 0, do: Logger.debug("aiur_perf github_comments_poller published count=#{count}")
    if errors != [], do: Logger.warning("GithubCommentsPoller partial failures; reason=#{inspect(errors)}")
    connectivity = if all_comment_targets_failed?(targets, errors), do: {:failure, comments_poll_classification(errors)}, else: :success

    cursor = %{
      cursor
      | since: TargetSelection.merge_comment_cursors(cursor.since, since),
        etags: Map.merge(cursor.etags, etags),
        issue_updated_at: TargetSelection.remember_polled_human_review_targets(cursor.issue_updated_at, human_review_targets, errors)
    }

    {cursor, %{connectivity: [connectivity], pr_review_seen_at: seen, pr_draft_observations: Map.get(polled, :pr_draft_observations, [])}}
  end

  defp poll_prepared_targets([], _poll_opts), do: :no_targets

  defp poll_prepared_targets(targets, poll_opts) when is_list(targets) do
    {targets, GithubCommentsPoller.poll(targets, poll_opts)}
  end

  defp prepare_comment_poll_opts(%Cursor{}, _input, [], _human_review_targets, _watch_targets, opts), do: opts

  defp prepare_comment_poll_opts(%Cursor{} = state, input, targets, human_review_targets, watch_targets, opts) when is_list(targets) do
    review_submission_targets = MapSet.new(human_review_targets, & &1.target)

    poll_opts =
      opts
      |> Keyword.put_new(:since, state.since)
      |> Keyword.put_new(:etags, state.etags)
      |> TargetSelection.put_open_pull_requests_by_target(human_review_targets)
      |> TargetSelection.put_open_pull_requests_by_target(watch_targets)
      |> Keyword.put_new(:titles_by_target, input.running_titles)
      |> Keyword.put(:review_submission_targets, review_submission_targets)
      |> Keyword.put(:pr_review_seen_at, Keyword.get(opts, :pr_review_seen_at, %{}))
      |> Keyword.put(:pr_ready_ledger, ready_ledger(opts))

    put_comment_batch(poll_opts, targets)
  end

  defp ready_ledger(opts) do
    case Keyword.get(opts, :pr_ready_ledger) do
      ledger when is_map(ledger) -> ledger
      _unloaded -> Keyword.get(opts, :load_pr_ready_ledger, fn -> %{} end).()
    end
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
