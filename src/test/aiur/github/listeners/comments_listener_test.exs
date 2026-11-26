defmodule Aiur.GitHub.Listeners.CommentsListenerTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.Listeners
  alias Aiur.GitHub.Listeners.Comments
  alias Aiur.GitHub.Listeners.Comments.{Cursor, Input}
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{CommentPollingState, State, TrackerHealth}

  setup do
    Listeners.reset()
    on_exit(fn -> Listeners.reset() end)
    :ok
  end

  test "orchestrator receives an outcome without owned-poll protocol messages" do
    orchestrator = Process.whereis(Orchestrator)
    :erlang.trace(orchestrator, true, [:receive, {:tracer, self()}])
    on_exit(fn -> if Process.alive?(orchestrator), do: :erlang.trace(orchestrator, false, [:receive]) end)

    :sys.replace_state(orchestrator, fn state ->
      CommentPollingState.start_async(state, empty_poll_opts())
    end)

    receive_barrier({:trace, ^orchestrator, :receive, {:github_listener_outcome, :comments, outcome}})
    assert is_reference(outcome.completion)
    barrier = :erlang.trace_delivered(orchestrator)
    receive_barrier({:trace_delivered, ^orchestrator, ^barrier})
    refute_received {:trace, ^orchestrator, :receive, {:github_comment_poll_started, _, _, _}}
    refute_received {:trace, ^orchestrator, :receive, {:github_comment_poll_guarding, _, _, _}}
    refute Map.has_key?(:sys.get_state(orchestrator), :github_comment_cursor)
  end

  test "reset terminates the in-flight poll and clears the cursor" do
    listener = start_supervised!({Comments, []})
    parent = self()
    opts = empty_poll_opts() |> Keyword.put(:server, listener) |> Keyword.put(:recipient, parent)

    opts =
      Keyword.put(opts, :review_issue_fetcher, fn _ ->
        send(parent, {:blocking_setup, self()})
        Process.sleep(:infinity)
      end)

    Listeners.start_comment_poll(input(), opts)
    receive_barrier({:blocking_setup, worker})
    before = :sys.get_state(listener)
    poll = before.cursor.poll.pid
    owner = before.cursor.poll.owner
    refs = for pid <- [worker, poll, owner], do: {pid, Process.monitor(pid)}
    assert :ok = GenServer.call(listener, :reset)
    for pid <- [worker, poll, owner], do: refute(Process.alive?(pid))
    for {pid, ref} <- refs, do: receive_barrier({:DOWN, ^ref, :process, ^pid, _reason})
    assert :sys.get_state(listener).cursor == %Cursor{}
  end

  test "a webhook hint reaches the listener through the orchestrator" do
    orchestrator = Process.whereis(Orchestrator)
    previous = :sys.get_state(orchestrator)
    :sys.replace_state(orchestrator, &%{&1 | poll_frozen: true})
    on_exit(fn -> :sys.replace_state(orchestrator, fn _ -> previous end) end)
    send(orchestrator, {:github_webhook_reconcile, %{kind: :review_thread, ticket: "7"}})
    # The orchestrator barrier proves forwarding happened before the listener barrier.
    :sys.get_state(orchestrator)
    assert :sys.get_state(Comments).cursor.reconcile_targets == MapSet.new(["7"])
  end

  test "outcome after reset is dropped" do
    listener = start_supervised!({Comments, []})
    parent = self()
    opts = Keyword.merge(empty_poll_opts(), server: listener, recipient: parent)

    opts =
      Keyword.put(opts, :review_issue_fetcher, fn _ ->
        send(parent, :blocked_for_reset)
        Process.sleep(:infinity)
      end)

    Listeners.start_comment_poll(input(), opts)
    receive_barrier(:blocked_for_reset)
    ref = :sys.get_state(listener).cursor.poll.ref
    GenServer.call(listener, :reset)
    payload = {:ok, %{}, [], {["7"], {:ok, %{since: %{"7" => "new"}, etags: %{}, count: 0, errors: [], pr_review_seen_at: %{"7" => "new"}}}}}
    send(listener, {:github_comments_polled, ref, payload})
    assert :sys.get_state(listener).cursor == %Cursor{}
    refute_received {:github_listener_outcome, :comments, _}
  end

  test "completion waits for folded backoff before retrying queued hints" do
    listener = start_supervised!({Comments, []})
    parent = self()
    opts = Keyword.merge(empty_poll_opts(), server: listener, recipient: parent)

    opts =
      Keyword.put(opts, :review_issue_fetcher, fn _ ->
        send(parent, {:release_setup, self()})

        receive do
          :finish -> {:ok, []}
        end
      end)

    Listeners.start_comment_poll(input(), opts)
    receive_barrier({:release_setup, worker})
    Listeners.reconcile_hint(%{kind: :review_thread, ticket: "7"}, input(), opts)
    assert :sys.get_state(listener).cursor.reconcile_targets == MapSet.new(["7"])
    send(worker, :finish)
    receive_barrier({:github_listener_outcome, :comments, outcome})
    assert :sys.get_state(listener).cursor.reconcile_timer == nil
    Listeners.update_backoff(60_000, server: listener, completion: outcome.completion)
    next = :sys.get_state(listener)
    assert next.pending_finish == nil
    assert next.cursor.reconcile_targets == MapSet.new(["7"])
    assert next.cursor.reconcile_timer.delay_ms == 60_000
  end

  test "tracker health pushes changes to the listener backoff" do
    Listeners.reconcile_hint(%{kind: :review_thread, ticket: "7"}, input(), poll_frozen: true, recipient: self())
    :sys.get_state(Comments)
    state = TrackerHealth.note_github_poll_interval(%State{}, :firehose, 60)
    assert :sys.get_state(Comments).input.next_github_delay_ms == 60_000
    TrackerHealth.note_github_connectivity_success(state, :firehose)
    assert :sys.get_state(Comments).input.next_github_delay_ms == nil
  end

  test "a reconcile timer consumed while awaiting backoff is rescheduled" do
    listener = start_supervised!({Comments, []})
    parent = self()
    opts = Keyword.merge(empty_poll_opts(), server: listener, recipient: parent)

    opts =
      Keyword.put(opts, :review_issue_fetcher, fn _ ->
        send(parent, {:release_timer_setup, self()})

        receive do
          :finish -> {:ok, []}
        end
      end)

    delayed = %{input() | next_github_delay_ms: 60_000}
    Listeners.reconcile_hint(%{kind: :review_thread, ticket: "7"}, delayed, opts)
    timer = :sys.get_state(listener).cursor.reconcile_timer
    Listeners.start_comment_poll(delayed, opts)
    receive_barrier({:release_timer_setup, worker})
    # This target is queued after the ordinary poll has claimed its batch.
    Listeners.reconcile_hint(%{kind: :review_thread, ticket: "8"}, delayed, opts)
    :sys.get_state(listener)
    send(worker, :finish)
    receive_barrier({:github_listener_outcome, :comments, outcome})
    send(listener, {:run_github_comment_reconcile, timer.token})
    assert :sys.get_state(listener).cursor.reconcile_timer == nil
    Listeners.update_backoff(60_000, server: listener, completion: outcome.completion)
    next = :sys.get_state(listener)
    assert next.cursor.reconcile_timer.token != timer.token
    assert next.cursor.reconcile_timer.delay_ms == 60_000
    assert next.cursor.reconcile_targets == MapSet.new(["8"])
  end

  test "the completion acknowledgement refreshes review observations before follow-up polls" do
    state = %State{pr_review_seen_at: %{"7" => "old-review"}, pr_ready_ledger: %{}}
    CommentPollingState.start_async(state, empty_poll_opts())
    receive_barrier({:github_listener_outcome, :comments, outcome})
    folded = CommentPollingState.apply_outcome(%{state | pr_review_seen_at: %{"7" => "new-review"}}, outcome)
    listener = :sys.get_state(Comments)
    assert listener.pending_finish == nil
    assert listener.opts[:pr_review_seen_at] == folded.pr_review_seen_at
    assert listener.opts[:pr_review_seen_at] == %{"7" => "new-review"}
    assert listener.opts[:pr_ready_ledger] == %{}
  end

  defp input, do: %Input{running_targets: [], running_titles: %{}, ownership_key: self(), next_github_delay_ms: nil}

  defp empty_poll_opts do
    [
      tracker_kind: "github",
      repo: "owner/repo",
      token: "test-gh-token",
      review_issue_fetcher: fn _ -> {:ok, []} end,
      watch_pull_request_fetcher: fn _ -> {:ok, []} end,
      comment_batch_fetcher: fn targets, _ ->
        {:ok, Map.new(targets, &{&1, %{open_pull_request: nil, issue_comments: [], pr_issue_comments: [], review_thread_comments: []}})}
      end,
      request_fun: fn _ -> {:ok, %{status: 304, headers: []}} end
    ]
  end
end
