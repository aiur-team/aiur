defmodule Aiur.BuildOrder.Cadence do
  @moduledoc """
  Derives Build Order's refresh cadences from the tracker's poll interval.

  ## What survives a cadence, and what does not

  Two of the four settings this module used to derive no longer exist:
  `graph_demand_refresh_ms` and `graph_selected_refresh_ms` were deleted, not
  retuned. They were the settings by which *viewing* bought GitHub reads — one
  firing when an operator selected a root, one repeating for as long as the page
  stayed open — and no value makes that correct, because the cost then tracks who
  is looking rather than what has changed. A selected root is now read when a
  writer or an explicit `GraphProjection.refresh/2` asks for it.

  What is left here is the cadence of the catalog's refreshes **while a Build
  Order page is open** (#2312), plus one freshness window. For those a number is
  still needed, and the durable statement is the *relationship*: **Build Order
  displays state the tracker produces, so it cannot be fresher than the tracker's
  own cycle.** The shipped constants were chosen when the tracker polled every 5
  seconds; #2064 moved it to 120 and they did not follow, because nothing tied
  them together. Expressing them against the poll interval is what stops that
  recurring.

  The catalog no longer runs for nobody: `GraphProjection` gates it on a viewer
  being present, so a headless run buys none of it. The *interval* derived here
  is what the catalog uses while a page is open, and it is still the tracker
  interval — a number that describes the fleet's real cycle, not who is looking.

  ## Which poll interval — the effective one, not the configured one

  "The tracker's own cycle" is `Aiur.PollCadence.effective_interval_ms/1`, not
  `polling.interval_seconds`. The dispatcher composes `webhooks.poll_widen_factor`
  and `polling.idle_widen_factor` on top of the base before it schedules a tick,
  and publishes what it actually scheduled. Deriving from the base instead is the
  same class of bug this module was written to stop: at the shipped defaults an
  idle fleet polls the tracker every 600s while the catalog kept firing every
  120s, so the projection ran **five times more often than the thing it projects**
  — 30 GraphQL requests an hour, unconditional, with nobody watching (#2118).

  A daemon-owned reconciliation that runs for nobody must widen when the fleet
  goes idle, exactly like the tracker it mirrors. It narrows again on its own:
  `GraphProjection` re-reads these options on every reconcile, so the first tick
  after the fleet picks up work is computed at the tight value.

  ## The ratios

    * `catalog_refresh_ms` — **one effective poll interval.** The interval of the
      catalog's refresh while a Build Order page is open. The catalog is the
      daemon's only reader of the Build Order projection, and it is what notices
      a root appearing or changing, so while anyone is looking it reconciles at
      the tracker's own cycle. Refreshing faster than the tracker cannot show
      anything new. It cannot be revalidated (see below), so cadence is the only
      control it has. When no page is open it does not run at all.

    * `catalog_labels_refresh_ms` — **five effective poll intervals, and never less than
      ten minutes.** This is the variant that resolves per-member labels, and it
      costs 26 points per page against the cheap read's 1 (#1766), so it is
      deliberately the slowest thing here. It is also floored at the catalog
      cadence, because a labels read that outran the poll it rides on would make
      every poll buy the expensive query — the exact regression #1766 exists to
      prevent, and one the schema rejects outright.

    * `ticket_detail_freshness_ms` — **a quarter of the base poll interval**, and
      the one value here that is deliberately *not* taken from the effective
      one. It is not a cadence at all: nothing fires on it. It is the staleness
      the Build Order ticket-detail drawer will accept from
      `Aiur.GitHub.ResourceStore` before revalidating — a display budget, not a
      safety budget, and no orchestrator or agent decision reads it. It is also
      the one read here that is REST and therefore conditional: an unchanged
      refresh is a `304` and costs no primary rate limit, and a ticket the
      orchestrator's per-issue poll already fetched costs nothing at all.

      It stays on the base interval because `TicketDetailCoordinator` reads it
      once, in `init/1`, and never re-derives it. Taken from the effective
      interval it would freeze at whatever the cadence was at boot — the widest
      the configuration permits, since nothing has been published yet — and
      would never narrow when the fleet picked up work.

  ## What is still not revalidatable

  GitHub's GraphQL API returns no `ETag`, no `Last-Modified` and no
  `Cache-Control` on any response, and every query is a `POST`. There is no
  conditional request to make, so `AiurBuildOrderCatalog`,
  `AiurBuildOrderSelectedRoot` and `AiurLinkedPullRequests` cannot answer `304`
  no matter how they are written. For those three, *when* they run and how large
  a connection they ask for are the entire cost story — which is why the two that
  ran on a viewer's behalf were removed outright, and the remaining one, the
  catalog, is tied to the tracker here *and* gated on a viewer being present
  (#2312): it refreshes at the tracker's cadence while a Build Order page is
  open, and not at all otherwise.

  An explicit setting always wins. These are defaults for operators who have not
  expressed a requirement, not a ceiling on ones who have.
  """

  alias Aiur.PollCadence

  # What an unreadable `polling.interval_seconds` derives from: the shipped
  # tracker default (#2064), so a bad number costs freshness rather than budget.
  @fallback_interval_ms 120_000

  @labels_multiplier 5
  @min_labels_refresh_ms 600_000
  @detail_divisor 4
  @min_detail_freshness_ms 5_000

  # Mirrors `Aiur.Config.Schema.BuildOrder`'s validation ceilings. A derived
  # value must land inside the range an operator would be allowed to type, or a
  # long poll interval would produce a default the schema itself rejects.
  @max_catalog_refresh_ms 3_600_000
  @max_labels_refresh_ms 3_600_000
  @max_detail_freshness_ms 300_000

  @type t :: %{
          graph_catalog_refresh_ms: pos_integer(),
          graph_catalog_labels_refresh_ms: pos_integer(),
          ticket_detail_freshness_ms: pos_integer()
        }

  @doc """
  The cadences implied by a tracker poll interval, in milliseconds.

  A nonsensical interval falls back to the shipped tracker default rather than
  raising: this is read on the way to starting a supervised process, and a bad
  number in configuration should slow the page down, not prevent it booting.

  The fallback is deliberately slow, not fast. An earlier version fell back to one
  second, which would have turned a typo in `polling.interval_seconds` into a
  one-second catalog cadence — a fail-safe pointing the wrong way, at the one read
  whose cost is entirely governed by how often it runs.
  """
  @spec derive(pos_integer() | any()) :: t()
  def derive(poll_interval_seconds) do
    poll_interval_seconds |> interval_ms() |> derive_ms()
  end

  @doc """
  The cadences implied by the interval the tracker is *actually* keeping.

  This is what production reads. It differs from `derive/1` on the configured
  interval by exactly the widening factors the dispatcher applied — at the
  shipped defaults, a factor of 5 while the fleet is idle.

  The catalog is a `:planning`-class read: its cadence resolves from the
  planning interval (`polling.intervals.planning`, falling back to
  `polling.interval_seconds`) rather than the bare global interval, so an
  operator can run the expensive Build Order reads at 10 minutes while dispatch
  stays at 2 (#2309).

  Before the dispatcher has published anything — which is every boot, since
  `:persistent_term` does not survive a VM restart, and `GraphProjection` starts
  ahead of the `Orchestrator` — this falls back to the **base** interval rather
  than to `PollCadence`'s own widest-configured answer. That fallback is
  deliberately the widest because its usual callers are staleness thresholds,
  where calling fresh data stale is the dangerous direction. A cadence has the
  opposite asymmetry: too wide delays discovering a root that appeared. Booting
  at the base is therefore never worse than the behaviour this replaced, and the
  first published cycle widens it.
  """
  @spec effective(keyword()) :: t()
  def effective(opts \\ []) do
    opts |> effective_interval_ms() |> derive_ms()
  end

  defp effective_interval_ms(opts) do
    case Keyword.get(opts, :effective_interval_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _unset -> PollCadence.published_effective_interval_ms(class: :planning) || PollCadence.base_interval_ms(Keyword.put(opts, :class, :planning))
    end
  end

  @doc """
  The cadences implied by an interval already expressed in milliseconds.
  """
  @spec derive_ms(pos_integer() | any()) :: t()
  def derive_ms(interval_ms) when not (is_integer(interval_ms) and interval_ms > 0) do
    derive_ms(@fallback_interval_ms)
  end

  def derive_ms(interval_ms) do
    catalog = clamp(interval_ms, 1, @max_catalog_refresh_ms)

    %{
      graph_catalog_refresh_ms: catalog,
      # The labelled catalog read costs 26 points per page against 1 for the
      # cheap one (#1766), so it runs far more slowly — but it must never run
      # *faster* than the catalog poll it rides on, which the schema enforces and
      # a long poll interval would otherwise violate.
      graph_catalog_labels_refresh_ms:
        interval_ms
        |> Kernel.*(@labels_multiplier)
        |> max(@min_labels_refresh_ms)
        |> max(catalog)
        |> clamp(1, @max_labels_refresh_ms),
      ticket_detail_freshness_ms:
        interval_ms
        |> div(@detail_divisor)
        |> max(@min_detail_freshness_ms)
        |> clamp(1, @max_detail_freshness_ms)
    }
  end

  @doc """
  Resolves one cadence against the interval the tracker is actually keeping,
  preferring an explicit setting over the derived default.

  Callers reading more than one key should call `effective/1` once and pass the
  result to `prefer_configured/3` instead, so the derivation is not repeated.
  """
  @spec resolve_effective(atom(), integer() | nil, keyword()) :: pos_integer()
  def resolve_effective(key, configured, opts \\ []) do
    prefer_configured(configured, effective(opts), key)
  end

  @doc """
  An explicit setting when there is one, otherwise `key` from an already-derived
  cadence map.

  A stored zero or negative is not a deliberate setting but a broken one, and
  honouring it would mean a refresh loop with no interval.
  """
  @spec prefer_configured(integer() | nil, t(), atom()) :: pos_integer()
  def prefer_configured(configured, _derived, _key) when is_integer(configured) and configured > 0 do
    configured
  end

  def prefer_configured(_configured, derived, key), do: Map.fetch!(derived, key)

  @doc """
  Resolves one cadence against an explicitly supplied poll interval in seconds.

  For the one caller that must not read the ambient cadence:
  `TicketDetailCoordinator` reads its options once at boot and never re-derives
  them, so a value taken from the effective interval would freeze at whatever
  the cadence happened to be when the daemon started.
  """
  @spec resolve(atom(), integer() | nil, pos_integer() | any()) :: pos_integer()
  def resolve(key, configured, poll_interval_seconds)

  def resolve(_key, configured, _poll_interval_seconds) when is_integer(configured) and configured > 0 do
    configured
  end

  def resolve(key, _configured, poll_interval_seconds) do
    poll_interval_seconds |> derive() |> Map.fetch!(key)
  end

  defp interval_ms(seconds) when is_integer(seconds) and seconds > 0, do: seconds * 1_000
  defp interval_ms(_seconds), do: @fallback_interval_ms

  defp clamp(value, minimum, maximum), do: value |> max(minimum) |> min(maximum)
end
