defmodule Aiur.GitHub.ResourceStore.Retention do
  @moduledoc """
  ## Retention

  Entries expire after 72 hours, matching `Aiur.Webhooks.DeliveryLog`: that is
  the envelope inside which GitHub will still retry a delivery, so it is the
  window in which a duplicate can still legitimately arrive.

  What "expired" means is judged on the field that owns the answer: a held body
  by its own `fetched_at_ms` (the same field `fetch/1` declines on), and a
  bodyless entry — a validator or a processed mark — by `recorded_at_ms`.
  Judging a body by `recorded_at_ms` would be wrong, because every write
  touches that field: a poll republish re-marking a processed comment keeps a
  three-day-old body looking current, and the eviction sweep would never delete
  it. The sweep, the read and the restart filter all use the same decision, and
  the decision distinguishes the entry from the body it happens to hold: an
  entry whose `recorded_at_ms` is itself past retention is deleted whole, while
  a body past retention inside an entry still in use is dropped — the processed
  mark and the validator survive, because they are what stop a duplicate
  dispatch and make the next read free. Truly outdated data is deleted rather
  than merely hidden on read.

  The drop is itself a write, so the now-bodyless entry's `recorded_at_ms` is
  refreshed by its own eviction — it rides that fresh clock for another full
  window before pass 1 can take it. One-shot, not a loop: pass 2 cannot match
  a body that is already gone, and a bodyless mark riding `recorded_at_ms` is
  the intent, so the two passes are not independent in time.

  """

  alias Aiur.GitHub.ResourceStore.{Cas, Checkpoint, Memory}
  import Aiur.GitHub.ResourceStore.Storage, only: [now_ms: 0]
  @retention_ms 72 * 60 * 60 * 1000

  @spec retention_ms() :: pos_integer()
  def retention_ms, do: @retention_ms

  # Only ever reached with an integer: `processed?/1` guards on `is_integer/1`
  # before asking, so a second catch-all clause here would be unreachable.
  @spec expired?(integer()) :: boolean()
  def expired?(at) when is_integer(at), do: now_ms() - at > @retention_ms

  # An entry is truly outdated when nothing in it is in use any more, and that
  # is judged on the field that owns the answer.
  #
  # `recorded_at_ms` is bumped by every write, so an entry whose recorded_at is
  # itself past cutoff has had no write in the whole window: body, validator and
  # mark are all dead, and the whole entry goes. A body, in contrast, is judged
  # by `fetched_at_ms` — the same field `fetch/1` refuses an expired body on —
  # because a poll republish re-marking a processed comment, or a `304`
  # re-recording a validator, refreshes `recorded_at_ms` while leaving a body
  # three days old. Such an entry is not truly outdated: its mark and its
  # validator are still in use, so the body is dropped and the entry stands.
  @spec entry_expired?(map(), integer()) :: boolean()
  def entry_expired?(entry, cutoff) do
    # The `|| 0` is the same nil-safe idiom `fetch/1` uses, not a redundant
    # default: `Map.get/3`'s default only covers an *absent* key, so a
    # `recorded_at_ms: nil` — a corrupt checkpoint, a hand-written entry —
    # would otherwise compare `nil < cutoff` and read as *not* expired,
    # because Erlang's term order sorts atoms after numbers
    # (`number < atom < ...`), so `nil < cutoff` is `false`. Treating it as
    # `0` (long past retention) makes sweep, read and restart agree that an
    # entry whose age nothing records is gone.
    (Map.get(entry, :recorded_at_ms, 0) || 0) < cutoff
  end

  # Whether the held body (if any) is past retention — the same `fetch/1`
  # decline, so "past retention" means the same thing to the read, the sweep and
  # the restart filter. An entry holding no body has nothing to be old by.
  @spec body_expired?(map(), integer()) :: boolean()
  def body_expired?(entry, cutoff) do
    case Map.get(entry, :data) do
      nil -> false
      _body -> (Map.get(entry, :fetched_at_ms, 0) || 0) < cutoff
    end
  end

  # `drop_data/1`'s shape: the body and its version go, the validator and the
  # processed mark stay. Used by the sweep and by the boot filter, so the two
  # cannot disagree about what an expired body costs the entry.
  @spec drop_body(map()) :: map()
  def drop_body(entry), do: entry |> Map.delete(:data) |> Map.delete(:data_version)

  # Expiry and eviction are writes like any other, so neither is allowed to be a
  # check-then-act. Two things can be past retention, and they are removed in
  # two passes, each staying conditional on the entry it decided about.
  @spec sweep(:ets.table()) :: :ok
  def sweep(table) do
    cutoff = now_ms() - @retention_ms

    # Pass 1 — the whole entry is past retention. `recorded_at_ms` is bumped by
    # every write, so an entry whose recorded_at is itself past cutoff has had
    # no write in the whole window: body, validator and mark are all dead, and
    # the whole entry goes. One C-side match spec — nothing is copied into this
    # process — and the guard is re-evaluated at the instant of deletion, so an
    # entry a writer refreshed in the meantime no longer matches and survives.
    deleted_keys =
      :ets.select(table, [
        {{:"$1", %{recorded_at_ms: :"$2"}}, [{:<, :"$2", cutoff}], [:"$1"]}
      ])

    deleted =
      :ets.select_delete(table, [
        {{:_, %{recorded_at_ms: :"$1"}}, [{:<, :"$1", cutoff}], [true]}
      ])

    if deleted > 0, do: Checkpoint.remove_entries(deleted_keys)

    # Pass 2 — the body is past retention but the entry is still in use. An
    # entry is one flat map, and the processed mark and the validator on it must
    # outlive a body nothing can serve: `Aiur.Events.Publisher` gates dedup on
    # `processed?/2`, and the ETag is what makes the next read free. So the body
    # is dropped, matching `drop_data/1`'s "validator, no body" state, and the
    # entry stands. Only an entry whose `recorded_at_ms` is also past cutoff is
    # deleted whole, and that is pass 1 above.
    table
    |> expired_body_keys(cutoff)
    |> Enum.each(&drop_expired_body(table, &1, cutoff))

    # The backstop on what retention alone does not bound: body bytes, and far
    # above real volume, entry count. `Memory.enforce/1` sheds the least
    # recently written *bodies* — never whole entries, because the `:etag` and
    # the processed mark beside a body are state a later read is still entitled
    # to — and reports what the table holds.
    Memory.enforce(table)
    :ok
  end

  # Keys of the data-bearing entries whose body is past retention, collected by
  # match spec so the bodies themselves are never copied into this process. The
  # three arms mirror `body_expired?/2` exactly, so the sweep cannot disagree
  # with the read and the boot filter about which bodies are expired:
  #
  #   * an integer `fetched_at_ms` past the cutoff — the common case;
  #   * a nil `fetched_at_ms` — a corrupt checkpoint, a hand-written entry.
  #     `body_expired?/2` reads nil as the epoch (`|| 0`), and Erlang's term
  #     order sorts atoms *after* every number (`number < atom < ...`), so
  #     `nil < cutoff` is `false` — a plain `:<` guard would skip it;
  #   * an absent `fetched_at_ms` — a map pattern cannot require a key to be
  #     *absent*, so this arm matches the whole entry and rejects the key by
  #     name.
  #
  # All three require a non-nil body, which is the half of `body_expired?/2`
  # that says an entry holding no body has nothing to be old by.
  defp expired_body_keys(table, cutoff) do
    :ets.select(table, [
      {{:"$1", %{data: :"$2", fetched_at_ms: :"$3"}}, [{:andalso, {:not, {:==, :"$2", nil}}, {:<, :"$3", cutoff}}], [:"$1"]},
      {{:"$1", %{data: :"$2", fetched_at_ms: :"$3"}}, [{:andalso, {:not, {:==, :"$2", nil}}, {:==, :"$3", nil}}], [:"$1"]},
      {{:"$1", :"$2"}, [{:andalso, {:is_map_key, :data, :"$2"}, {:andalso, {:not, {:==, {:map_get, :data, :"$2"}, nil}}, {:not, {:is_map_key, :fetched_at_ms, :"$2"}}}}], [:"$1"]}
    ])
  end

  # The body of one entry, dropped conditionally inside the swap: only while the
  # entry still holds a body past retention. `update_reply/3`'s `:skip` is what
  # spares a body a writer deposited after the key was collected — the whole
  # point of the pin — and the drop is `drop_data/1`'s shape.
  defp drop_expired_body(table, key, cutoff) do
    Cas.update_reply(table, key, :ok, fn entry ->
      if body_expired?(entry, cutoff) do
        {drop_body(entry), :ok}
      else
        {:skip, :ok}
      end
    end)
  end
end
