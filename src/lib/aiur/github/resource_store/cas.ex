defmodule Aiur.GitHub.ResourceStore.Cas do
  @moduledoc """
  ## Changing a held body: never fetch-then-put

  A writer that reads the held body, changes part of it and puts it back must
  use `update_resource/3`, which does all three inside one compare-and-swap.
  The same thing written as `fetch/1` followed by `put_resource/3` loses writes
  within the first handful of concurrent merges, because the window is a whole
  round trip through the caller: a webhook delivery depositing the fresh object
  in between is overwritten by the stale snapshot, `"state"` included. There is
  no volume threshold below which this is safe.

  ## Which pipe wrote is not a change

  `:source` records the pipe that last marked a resource processed and
  `:data_source` the pipe that deposited the body; they are separate fields
  because one deposit and one mark used to overwrite each other's answer.
  Neither is part of what counts as a change. Two readers of the same unchanged
  resource — the ticket-detail path writing `:fetch` and the poll writing
  `:poll` — would otherwise alternate that field on every cycle and wake every
  subscriber of a resource that did not move. A subscriber that wants to know
  who paid reads it off the change event.

  """

  require Logger
  alias Aiur.GitHub.{MembershipAccess, ResourceEvents}
  alias Aiur.GitHub.ResourceStore.Checkpoint
  import Aiur.GitHub.ResourceStore.Storage, only: [with_table: 3, now_ms: 0]

  # Every write in the module funnels through here, which is why publication
  # lives here too: a writer that had to remember to announce would eventually
  # forget, and leave a subscribed view stale with no way to notice.
  #
  # Writes land in ETS from the caller's own process rather than through the
  # GenServer, because the poll fan-out writes one entry per comment and a single
  # mailbox would become the bottleneck this store exists to remove.
  #
  # A plain read-modify-write would not be safe at that concurrency, and the
  # danger is not the harmless one it looks like. Two writers share a key as soon
  # as one pipe deposits a body and another records a validator for the same
  # resource — `:pull_request` and `:issue` have exactly that pair of writers. A
  # `put_etag/2` that read `existing` *before* a concurrent `put_resource/3`
  # inserted the body would re-insert the entry without that body while keeping
  # the newer validator: a lost write, and specifically the bodyless-validator
  # pair this module refuses everywhere else, because the next reader then sends
  # `If-None-Match`, is told `304`, and holds nothing.
  #
  # So the modify is a compare-and-swap. `:ets.select_replace/2` only replaces
  # while the entry is still byte-for-byte the one this call read, and
  # `:ets.insert_new/2` only creates while there is still nothing there. A racing
  # writer makes this one read again and re-apply `fun`, so both writes survive.
  #
  # ## The retry budget is part of the guarantee, not a detail
  #
  # A bounded budget whose last resort is an unconditional insert is not a
  # compare-and-swap: it is a compare-and-swap with a lost update wired into its
  # exhaustion path. Measured on `:issue` with four writers doing 150 merges
  # each, contention is real (about 1.7 failed swaps per successful one) and the
  # losing writer is *not* independently unlucky — BEAM's reduction-based
  # preemption phase-locks a writer that keeps being descheduled in the same
  # window between its read and its swap, so runs of tens of consecutive
  # failures happen where independence would predict none. Every one of those
  # runs that reached the old budget of 50 blind-inserted a body derived from a
  # read that was by then dozens of generations stale: the held `"gen"` counter
  # went *backwards*, and the final count came out below the number of merges.
  # That is the exact lost update this function exists to prevent, arriving
  # through its own escape hatch. See #2128.
  #
  # So the budget still exists — an unbounded spin in a poll task is its own
  # failure — but it is spent differently and it ends differently:
  #
  #   * the first `@update_spin_attempts` retries are immediate, which is all
  #     ordinary contention ever needs;
  #   * after that each retry yields the scheduler first, which breaks the
  #     phase-lock by moving this process's reduction budget relative to its
  #     competitors;
  #   * after that each retry sleeps a randomised millisecond, which decorrelates
  #     writers outright;
  #   * and if even that budget runs out the write is **abandoned**, never
  #     forced. Abandoning costs a reader one full-price fetch, which is this
  #     module's documented fail-open direction. Forcing costs correctness: a
  #     reader served `open` for a ticket Aiur has closed.
  @update_spin_attempts 8
  @update_yield_attempts 64
  @update_backoff_attempts 128
  @update_attempts @update_spin_attempts + @update_yield_attempts + @update_backoff_attempts

  @spec update(:ets.table(), term(), (map() -> map())) :: :ok
  def update(table, key, fun), do: MembershipAccess.run(key, :ok, fn -> update_entry(table, key, fun) end)

  defp update_entry(table, key, fun) do
    with_table(table, :ok, fn table ->
      {_reply, result} = update_cas(table, key, &{fun.(&1), :ok}, :ok, @update_attempts)
      result
    end)
  end

  # The reply-carrying form. `fun` answers `{entry, reply}`, so a caller whose
  # decision depends on what it found *inside* the swap can report that decision
  # without a second, racy read. `revalidate/3` is the reason it exists: whether a
  # `304` confirmed the held body or was superseded by a concurrent deposit is
  # only knowable at the instant of the compare-and-swap.
  #
  # `default` is also the answer when the write is abandoned under pathological
  # contention, for the same reason it is the answer when no table exists: an
  # abandoned write has decided nothing, so the caller must be told the
  # fail-open thing rather than a decision that never happened.
  @spec update_reply(:ets.table(), term(), term(), (map() -> {map() | :skip, term()})) :: term()
  def update_reply(table, key, default, fun),
    do: MembershipAccess.run(key, default, fn -> update_entry_reply(table, key, default, fun) end)

  defp update_entry_reply(table, key, default, fun) do
    with_table(table, default, fn table ->
      {reply, _result} = update_cas(table, key, fun, default, @update_attempts)
      reply
    end)
  end

  defp update_cas(table, key, fun, abandon_reply, attempts_left) do
    existing =
      case :ets.lookup(table, key) do
        [{^key, entry}] -> entry
        _other -> nil
      end

    case fun.(existing || %{}) do
      # `fun` decided, against the entry as it stands inside the swap, that there
      # is nothing to write. Not a failed swap and not a dropped write — the
      # decision *is* the outcome, so no entry is created and nothing is
      # announced. Without this a caller that only conditionally writes has to
      # make its decision outside the swap, which is check-then-act.
      {:skip, reply} ->
        {reply, :ok}

      {entry, reply} ->
        entry = Map.put(entry, :recorded_at_ms, now_ms())

        if swapped?(table, key, existing, entry) do
          Checkpoint.mark_entry_dirty(key)
          announce(key, existing || %{}, entry)
          {reply, :ok}
        else
          retry_update(table, key, fun, abandon_reply, attempts_left - 1)
        end
    end
  end

  # Budget spent. The write is dropped rather than forced: `entry` was derived
  # from a read the table has already moved past, so inserting it would roll the
  # held body back to a state no writer intends — and `entry` is deliberately not
  # touched here so that cannot be done by accident. A dropped store write costs
  # one full-price read; a forced stale one costs correctness.
  defp retry_update(_table, key, _fun, abandon_reply, attempts_left) when attempts_left <= 0 do
    Logger.error(
      "GitHub.ResourceStore abandoned a contended write for #{inspect(key)} after #{@update_attempts} attempts; " <>
        "the newer held entry is kept and this write is dropped rather than rolling the body back"
    )

    {abandon_reply, :ok}
  end

  defp retry_update(table, key, fun, abandon_reply, attempts_left) do
    pace(attempts_left)
    update_cas(table, key, fun, abandon_reply, attempts_left)
  end

  # Immediate while contention is ordinary, then progressively decorrelating. The
  # yield is what breaks a reduction-phase lock-step; the randomised sleep is the
  # backstop for a writer that is losing for a reason yielding cannot move.
  defp pace(attempts_left) when attempts_left > @update_yield_attempts + @update_backoff_attempts, do: :ok

  defp pace(attempts_left) when attempts_left > @update_backoff_attempts do
    :erlang.yield()
    :ok
  end

  defp pace(_attempts_left), do: Process.sleep(:rand.uniform(2))

  # `select_replace/2` matches on the whole stored object, so the guard pins the
  # entry this call actually read. `insert_new/2` covers the "was absent" case,
  # which `select_replace/2` cannot express.
  defp swapped?(table, key, nil, entry), do: :ets.insert_new(table, {key, entry})

  defp swapped?(table, key, existing, entry) do
    match_spec = [{{key, :"$1"}, [{:==, :"$1", {:const, existing}}], [{:const, {key, entry}}]}]
    :ets.select_replace(table, match_spec) == 1
  end

  # A write that leaves the entry's observable content unchanged is silent. Only
  # `recorded_at_ms` moved, so no subscriber could see a difference, and a sweep
  # re-recording an unchanged validator across the whole retention window would
  # otherwise trade the poll this store removes for a broadcast storm.
  defp announce(key, before, entry) do
    if observable(before) == observable(entry) do
      :ok
    else
      ResourceEvents.publish(key, entry)
    end
  end

  # `:data` is the load-bearing member. A body can arrive against an unchanged
  # validator — a first deposit for a resource whose ETag a sweep already
  # recorded — and that is precisely the write a viewer is waiting for, because
  # the held body is the only thing that decides whether a page has anything to
  # render. Comparing whole bodies is affordable: they are size-bounded, and an
  # identical body rewritten is a genuine no-op no subscriber should be woken for.
  #
  # Which pipe wrote it is *not* observable, and leaving it in was a broadcast
  # storm waiting for its first subscriber. The same unchanged issue read by the
  # ticket-detail path (`:fetch`) and by the poll (`:poll`) alternates that field
  # on every cycle while nothing a viewer renders moves at all, so every reader
  # of a quiet resource would have woken every subscriber of it, forever. A
  # subscriber that wants to know who paid reads it off the change event.
  defp observable(entry) do
    Map.take(entry, [:etag, :data, :data_version, :processed_at_ms, :version])
  end
end
