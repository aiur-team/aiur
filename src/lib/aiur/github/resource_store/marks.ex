defmodule Aiur.GitHub.ResourceStore.Marks do
  @moduledoc """
  ## What an entry holds

    * `:etag` — the validator for a conditional re-read. A `304` costs nothing
      against GitHub's primary REST limit, so a sweep over unchanged resources
      is free rather than merely cheap.
    * `:processed_at_ms` — the moment some pipe finished processing this exact
      resource. This is the suppress half of the sweep.
    * `:version` — the resource's own mutation marker, a comment's `updated_at`.

  ## Identity says *which* resource; version says *which state of it*

  A GitHub comment is mutable. An edit keeps the id and moves only `updated_at`,
  and the sweep's `?since=` filter is on `updated_at`, so an edited comment comes
  back around on the next cycle. Suppressing on identity alone would read that as
  a redelivery of the original and swallow it for the full retention window —
  three days, across restarts. Editing a comment to correct an agent's
  instructions is a normal workflow here, so that would be a real loss.

  So a mark records the version it was made at, and a resource whose version has
  moved reads as unprocessed. Note this is *not* a watermark: nothing is compared
  for order, only for equality against the version that was actually processed.
  An older lost comment still recovers, because it is a different resource
  entirely.

  Shortening the retention window would have bought the edit back by giving up
  the thing the window exists for — a delivery GitHub retries up to three days
  later — so the version is recorded instead.

  Suppression is nevertheless **bounded**, and the bound depends on whether a
  version stands behind the mark. A versioned mark is released by the resource
  changing, so the clock does not have to release it and it may hold for the full
  retention window. A mark with no version can only ever be released by the
  clock, so it holds for `unversioned_suppression_ms/0` instead — otherwise one
  mapping mistake hides a resource for three days with nothing to attribute it
  to. See `@unversioned_suppression_ms`.

  ## Suppress and recover are not in tension once the key is identity

  The sweep must not re-process what the webhook already delivered, and it must
  still recover a delivery that was lost. Measured here: 9 of 100 deliveries
  returned 502 during a daemon restart, GitHub retried none, and none arrived
  later. Those two requirements only fight each other if suppression is decided
  by a *timestamp watermark* — "ignore anything older than the newest thing I
  saw" also ignores an older sibling whose delivery was dropped.

  Deciding per resource identity removes the conflict outright. A comment the
  webhook processed is marked and is skipped by name; a comment whose delivery
  was lost was never marked, so the very next sweep publishes it. The sweep
  itself is never skipped, so there is no window in which a gap cannot be seen.

  ## Two versions, deliberately kept apart

  `:version` is the version at which some pipe *processed* the resource, and it
  is the suppress half of the sweep. `:data_version` is the version of the body
  currently held. They are stored separately because merging them would be a
  suppression bug: a writer depositing newer data would otherwise silently drag
  an older processed-mark forward onto a version nothing has handled, and the
  event for that version would never be published. A deposit only advances
  `:version` when its caller passes `processed: true`, meaning "I have already
  done whatever this resource requires".
  """

  require Logger
  alias Aiur.GitHub.ResourceStore.Cas
  import Aiur.GitHub.ResourceStore.Storage, only: [lookup: 2, now_ms: 0]
  import Aiur.GitHub.ResourceStore.Retention, only: [expired?: 1]

  # The bound on suppression that has no version behind it.
  #
  # A *versioned* mark is safe to hold for the whole retention window because a
  # genuine change moves the version and unsuppresses the resource immediately —
  # time is not what releases it. A mark with **no** version cannot be released
  # that way at all: it suppresses on identity alone, so nothing the resource
  # does will ever unsuppress it and its only bound is the clock. Leaving that at
  # 72 hours means one mapping mistake — a writer that cannot read a version,
  # a resource shape whose marker moved — hides the resource for three days,
  # across restarts, with no error and nothing to attribute it to.
  #
  # 30 minutes is far longer than any duplicate-delivery burst (GitHub's
  # immediate retries are seconds apart) and short enough that a mistake costs
  # one delayed wake rather than a lost one. The failure this trades into is a
  # duplicate publish, which the publisher's own dedup window already absorbs,
  # and which every other trade-off in this module also chooses over a drop.
  @unversioned_suppression_ms 30 * 60 * 1000

  @type key :: Aiur.GitHub.ResourceStore.key()

  @spec processed?(:ets.table(), key() | nil, String.t() | nil) :: boolean()
  def processed?(table, key, version \\ nil)

  def processed?(_table, nil, _version), do: false

  def processed?(table, key, version) do
    processed_entry?(lookup(table, key), normalize_version(version))
  end

  # One definition of "already handled", shared by the read and by `claim/3`'s
  # compare-and-swap. Two copies of this predicate is how the two answers drift
  # apart, and a `claim/3` that disagreed with `processed?/2` would suppress an
  # event nothing had published.
  #
  # The bound lives here rather than in `processed?/2` for exactly that reason:
  # `claim/3` consults this predicate directly inside its swap, so a bound
  # applied only on the read path would leave the atomic claim suppressing
  # unversioned marks for the full retention window.
  defp processed_entry?(%{processed_at_ms: at} = entry, version) when is_integer(at) do
    marked = Map.get(entry, :version)
    marked == version and within_suppression_bound?(at, marked)
  end

  defp processed_entry?(_entry, _version), do: false

  @spec unversioned_suppression_ms() :: pos_integer()
  def unversioned_suppression_ms, do: @unversioned_suppression_ms

  @spec mark_processed(:ets.table(), key() | nil, atom(), String.t() | nil) :: :ok
  def mark_processed(table, key, source, version \\ nil)

  def mark_processed(_table, nil, _source, _version), do: :ok

  def mark_processed(table, key, source, version) when is_atom(source) do
    # Said out loud, because this is the mapping mistake the bound exists to
    # bound: a writer that could not read a version suppresses on identity alone,
    # and the only evidence anything went wrong is this line. `deposit/5` already
    # warns for the same case on the write path.
    if is_nil(normalize_version(version)) do
      Logger.warning(
        "GitHub.ResourceStore marked #{inspect(key)} processed with no version; " <>
          "suppression falls back to identity alone and expires after #{div(@unversioned_suppression_ms, 60_000)} minutes"
      )
    end

    Cas.update(table, key, fn entry ->
      entry
      |> Map.put(:processed_at_ms, now_ms())
      |> Map.put(:source, source)
      |> Map.put(:version, normalize_version(version))
    end)
  end

  @spec claim(:ets.table(), key() | nil, atom(), String.t() | nil) :: :marked | :already_processed
  def claim(table, key, source, version \\ nil)

  def claim(_table, nil, _source, _version), do: :marked

  def claim(table, key, source, version) when is_atom(source) do
    version = normalize_version(version)

    Cas.update_reply(table, key, :marked, fn existing ->
      if processed_entry?(existing, version) do
        {existing, :already_processed}
      else
        {existing
         |> Map.put(:processed_at_ms, now_ms())
         |> Map.put(:source, source)
         |> Map.put(:version, version), :marked}
      end
    end)
  end

  # A versioned mark rides the retention window; an identity-only mark rides the
  # much tighter bound, because nothing but the clock can ever release it.
  defp within_suppression_bound?(at, nil), do: now_ms() - at <= @unversioned_suppression_ms
  defp within_suppression_bound?(at, _version), do: not expired?(at)

  # A resource with no readable version is stored as `nil`, which matches only
  # another `nil` — so such a resource keeps the pre-version behavior of being
  # suppressed on identity alone. That is the right default: it is the current
  # behavior, and inventing a version would make every re-read look like an
  # edit and republish the whole window every cycle.
  @spec normalize_version(term()) :: String.t() | nil
  def normalize_version(version) when is_binary(version) and version != "", do: version
  def normalize_version(_version), do: nil
end
