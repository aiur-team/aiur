defmodule Aiur.GitHub.Listeners.Comments.Driver do
  @moduledoc "GitHub comment-poll driver on explicit cursors and plain inputs; owned by the comments listener."
  require Logger
  alias Aiur.{Config, PollCadence}
  alias Aiur.Events.GithubCommentsPoller
  alias Aiur.GitHub.Listeners.Comments.{Cursor, Input, OwnedPoll, Poll, Reconcile, TargetSelection}
  @retry_delay_ms 5_000
  @abandon_margin_ms 30_000

  @spec poll_github_comments(Cursor.t(), Input.t(), keyword()) :: {Cursor.t(), map()}
  def poll_github_comments(%Cursor{} = cursor, %Input{} = input, opts \\ []) do
    if Config.tracker_kind() == "github", do: Poll.apply(cursor, Poll.run(cursor, input, opts)), else: {cursor, %{}}
  end

  @spec start_async(Cursor.t(), Input.t(), keyword()) :: {Cursor.t(), map()}
  def start_async(%Cursor{} = cursor, %Input{} = input, opts \\ []) do
    now_ms = System.monotonic_time(:millisecond)

    cond do
      Keyword.get_lazy(opts, :tracker_kind, &Config.tracker_kind/0) != "github" ->
        {cursor, %{}}

      PollCadence.within_class_cadence?(cursor.last_started_at_ms, now_ms, :review) ->
        {cursor, %{}}

      true ->
        case prepare_start(cursor, input, opts, now_ms) do
          {:busy, cursor} -> {cursor, %{}}
          {:ready, cursor} -> {spawn_poll(cursor, input, opts, now_ms), %{}}
        end
    end
  end

  @spec request_reconcile(Cursor.t(), Input.t(), map(), keyword()) :: {Cursor.t(), map()}
  def request_reconcile(cursor, input, hint, opts \\ [])

  def request_reconcile(%Cursor{} = cursor, %Input{} = input, %{kind: :review_thread, ticket: ticket}, opts) when is_binary(ticket) do
    case String.trim(ticket) do
      "" -> {cursor, %{}}
      target -> {cursor |> Reconcile.admit(MapSet.new([target]), opts) |> Reconcile.schedule(input, 0, false, opts), %{}}
    end
  end

  def request_reconcile(%Cursor{} = cursor, %Input{}, _hint, _opts), do: {cursor, %{}}

  @spec apply_async(Cursor.t(), Input.t(), reference(), term(), keyword()) :: {Cursor.t(), map()}
  def apply_async(cursor, input, ref, payload, opts \\ [])

  def apply_async(%Cursor{poll: %{ref: ref} = poll} = cursor, %Input{}, ref, payload, _opts) do
    OwnedPoll.release_poll_owner(poll)
    OwnedPoll.demonitor_comment_poll(poll)
    retry_targets = Reconcile.failed_targets(poll, payload)
    {cursor, outcome} = cursor |> Map.put(:poll, nil) |> Reconcile.requeue(retry_targets) |> Poll.apply(payload)
    retry? = MapSet.size(retry_targets) > 0
    {cursor, Map.put(outcome, :reconcile, {if(retry?, do: @retry_delay_ms, else: 0), retry?})}
  end

  def apply_async(%Cursor{} = cursor, %Input{}, _stale_ref, _payload, _opts), do: {cursor, %{}}

  @spec apply_async_started(Cursor.t(), Input.t(), reference(), pid(), pid(), keyword()) :: {Cursor.t(), map()}
  def apply_async_started(cursor, input, ref, owner, pid, opts \\ [])

  def apply_async_started(%Cursor{poll: %{ref: ref, owner: owner} = pending} = cursor, %Input{}, ref, owner, pid, _opts) do
    monitor_ref = Process.monitor(pid)
    send(owner, {:start_owned_poll, self(), ref})
    poll = pending |> Map.put(:pid, pid) |> Map.put(:monitor_ref, monitor_ref) |> Map.put(:guarding?, false)
    {%{cursor | poll: poll}, %{}}
  end

  def apply_async_started(%Cursor{} = cursor, %Input{}, _stale_ref, owner, _pid, _opts) do
    send(owner, {:stop_owned_poll, self(), make_ref()})
    {cursor, %{}}
  end

  @spec apply_async_guarding(Cursor.t(), Input.t(), reference(), pid(), pid(), keyword()) :: {Cursor.t(), map()}
  def apply_async_guarding(cursor, input, ref, owner, pid, opts \\ [])

  def apply_async_guarding(%Cursor{poll: %{ref: ref, owner: owner, pid: pid} = poll} = cursor, %Input{}, ref, owner, pid, _opts),
    do: {%{cursor | poll: Map.put(poll, :guarding?, true)}, %{}}

  def apply_async_guarding(%Cursor{} = cursor, %Input{}, _stale_ref, owner, _pid, _opts) do
    send(owner, {:stop_owned_poll, self(), make_ref()})
    {cursor, %{}}
  end

  @spec apply_async_down(Cursor.t(), Input.t(), reference(), keyword()) :: {Cursor.t(), map()}
  def apply_async_down(cursor, input, ref, opts \\ [])

  def apply_async_down(%Cursor{poll: %{owner_monitor_ref: ref} = poll} = cursor, %Input{}, ref, _opts) do
    OwnedPoll.reap_poll_after_owner_down(poll)
    down_outcome(cursor, poll)
  end

  def apply_async_down(%Cursor{poll: %{monitor_ref: ref} = poll} = cursor, %Input{}, ref, _opts) do
    OwnedPoll.release_poll_owner(poll)
    OwnedPoll.demonitor_owner(poll)
    down_outcome(cursor, poll)
  end

  def apply_async_down(%Cursor{} = cursor, %Input{}, _stale_ref, _opts), do: {cursor, %{handled?: false}}

  defp down_outcome(cursor, poll),
    do: {cursor |> Reconcile.reclaim(poll) |> Map.put(:poll, nil), %{handled?: true, reconcile: {@retry_delay_ms, true}}}

  @spec run_scheduled_reconcile(Cursor.t(), Input.t(), reference(), keyword()) :: {Cursor.t(), map()}
  def run_scheduled_reconcile(cursor, input, token, opts \\ [])

  def run_scheduled_reconcile(%Cursor{reconcile_timer: %{token: token}} = cursor, %Input{} = input, token, opts) do
    cursor = %{cursor | reconcile_timer: nil}
    if Keyword.get(opts, :poll_frozen, false), do: {cursor, %{}}, else: start_async(cursor, input, Keyword.put(opts, :reconcile_only, true))
  end

  def run_scheduled_reconcile(%Cursor{} = cursor, %Input{}, _stale_token, _opts), do: {cursor, %{}}

  @doc false
  @spec finish(Cursor.t(), Input.t(), map(), keyword()) :: Cursor.t()
  def finish(%Cursor{} = cursor, %Input{} = input, outcome, opts) do
    case Map.get(outcome, :reconcile) do
      {minimum, replace?} -> Reconcile.schedule(cursor, input, minimum, replace?, opts)
      nil -> cursor
    end
  end

  @spec reconcile_retry_delay_ms(Input.t()) :: non_neg_integer()
  def reconcile_retry_delay_ms(%Input{} = input), do: max(@retry_delay_ms, input.next_github_delay_ms || 0)
  @spec terminate_poll(map() | nil) :: :ok
  defdelegate terminate_poll(poll), to: OwnedPoll

  defp prepare_start(%Cursor{poll: %{started_at_ms: started, abandon_after_ms: deadline}} = cursor, input, opts, now_ms)
       when is_integer(started) and is_integer(deadline) do
    if now_ms - started < deadline do
      {:busy, cursor}
    else
      Logger.warning("GithubCommentsPoller poll has not answered in #{deadline}ms; abandoning it and starting a fresh one")
      poll = cursor.poll
      abandon_poll(poll)
      cursor = cursor |> Reconcile.reclaim(poll) |> Map.put(:poll, nil)

      case input.next_github_delay_ms do
        delay when is_integer(delay) and delay > 0 -> {:busy, Reconcile.schedule(cursor, input, delay, true, opts)}
        _no_backoff -> {:ready, cursor}
      end
    end
  end

  defp prepare_start(cursor, _input, _opts, _now), do: {:ready, cursor}

  defp abandon_poll(%{owner: owner} = poll) when is_pid(owner) do
    OwnedPoll.terminate_poll(poll)
    OwnedPoll.demonitor_comment_poll(poll)
  end

  defp abandon_poll(_poll), do: :ok

  defp spawn_poll(cursor, input, opts, now_ms) do
    listener = self()
    ref = make_ref()
    targets = TargetSelection.reconcile_targets_for_poll(cursor, input, opts)
    poll_cursor = %{cursor | reconcile_targets: targets}
    task_fun = fn -> send(listener, {:github_comments_polled, ref, Poll.run(poll_cursor, input, opts)}) end
    {owner, monitor} = OwnedPoll.spawn_owned_poll(listener, input.ownership_key, ref, task_fun, Keyword.get(opts, :owner_phase_hook))
    target_count = TargetSelection.max_comment_poll_target_count(poll_cursor, input, opts)
    abandon_after = Poll.setup_timeout_ms(opts) + GithubCommentsPoller.max_duration_ms(target_count, opts) + @abandon_margin_ms
    poll = %{ref: ref, owner: owner, owner_monitor_ref: monitor, started_at_ms: now_ms, abandon_after_ms: abandon_after, reconcile_targets: targets}
    %{cursor | poll: poll, reconcile_targets: MapSet.difference(cursor.reconcile_targets, targets), last_started_at_ms: now_ms}
  end
end
