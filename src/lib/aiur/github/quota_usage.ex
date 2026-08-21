defmodule Aiur.GitHub.QuotaUsage do
  @moduledoc """
  A read-only projection of `Aiur.GitHub.Quota` shaped for the usage charts.

  The `/github-cache` page can answer "who is spending the GitHub budget" that
  the `aiur github-cost` CLI cannot: the CLI boots a throwaway BEAM and reads an
  empty meter, while the dashboard runs inside the daemon and reads the live
  one. This module is the arithmetic between that meter and a chart, kept pure
  so it can be tested against a fixed snapshot with no daemon.

  ## The two budgets are never summed

  Core bills requests and GraphQL bills points, on separate windows that reset
  at different times. Core sat at 88/5000 on the night GraphQL hit 0/5000, and
  a single "4% used" figure over the two would have described neither. So a
  projection is always *per budget*: `sample/2` returns a map keyed by resource
  and there is no combined total anywhere for a renderer to reach for.

  ## Whose remainder it is depends on how far back the meter can see

  `spend - attributed` is only *another consumer's* spend when this meter was
  running for the whole window. Attribution lives in `Quota`'s memory and dies
  with the process; the credential's window does not, and `/rate_limit` reports
  the full hour on the next refresh. So for up to an hour after every restart
  the remainder is inflated by the daemon's own forgotten calls.

  `observation_complete?` is that condition, and it is what the page switches
  its wording on. The band, the arithmetic and the reconciliation are identical
  either way — what changes is the claim about *whose* spend it is, which is the
  only part that was ever a guess. Saying "another consumer spent this" four
  minutes after a deploy would be the confident wrong number this page exists to
  refuse, committed by the surface built to refuse it.

  ## The remainder is the point

  The sum of the per-caller rows is `attributed` — what this daemon issued and
  could price. The credential's own window says what was actually spent. On a
  shared GitHub App installation the second is far larger than the first, and a
  chart drawn from the rows alone would show a confident, ranked, wrong picture
  of where a 5,000-point budget went. So `spend - attributed` is carried as its
  own band, `:outside`.

  `:outside` is deliberately *not* called "unattributed". `Quota` already uses
  that word for a call this daemon made and could not name, and it appears in
  the ranking as a caller row. Spend this daemon never issued is a different
  fact and gets a different word.

  ## Unobserved is not zero

  Every figure here can be absent, and absent is rendered as absent:

    * a meter with no observed window answers `nil` from `sample/2` — the
      sampler records nothing rather than a fabricated row of zeroes;
    * a budget whose window has passed its reset carries `spend: nil` and
      `outside: nil`, because `limit - remaining` then describes a window that
      has closed;
    * `series/2` draws only over the trailing run of samples where spend *was*
      observed, and reports how many it dropped, rather than joining a line
      across a gap it never measured.

  ## Reported is not assumed

  `Quota` prices GraphQL from GitHub's own `rateLimit { cost }` and falls back
  to `{1, :assumed}` when a response carried no price. `estimated?` rides on
  every caller row and on the budget, so an estimate is never presented as a
  measurement.
  """

  # How many caller rows get their own colour before the tail folds together.
  # Past this the categorical palette would have to cycle, and a cycled hue is
  # a chart that says two different callers are the same one.
  @top_callers 5

  # GraphQL first: it is the budget that exhausts. Order is fixed rather than
  # derived so the page's two blocks never swap places between renders.
  @budget_order ["graphql", "core"]

  @type band :: %{key: String.t(), label: String.t(), kind: :caller | :other | :outside, slot: pos_integer() | nil}

  @doc "The budgets this page renders, in the order it renders them."
  @spec budget_order() :: [String.t()]
  def budget_order, do: @budget_order

  @doc "How many callers get a colour of their own before the tail folds."
  @spec top_callers() :: pos_integer()
  def top_callers, do: @top_callers

  @doc """
  One time-series sample from a `Quota.snapshot/0`.

  Answers `nil` when the meter has observed no window, so a sampler records
  nothing rather than a row of zeroes that reads as "nothing was spent".
  """
  @spec sample(map(), DateTime.t()) :: map() | nil
  def sample(snapshot, now \\ DateTime.utc_now())

  def sample(%{} = snapshot, %DateTime{} = now) do
    windows = Map.get(snapshot, :windows) || %{}

    if Map.get(snapshot, :state) == :observed and map_size(windows) > 0 do
      %{
        t_ms: DateTime.to_unix(now, :millisecond),
        budgets: Map.new(windows, fn {resource, window} -> {resource, budget(snapshot, resource, window)} end)
      }
    end
  end

  def sample(_snapshot, _now), do: nil

  @doc """
  Could this meter have seen the whole window?

  True only when the meter was already observing when the window opened. False
  covers both the restart case and a meter with no boot time at all — in either
  the honest reading of the remainder is "spend this daemon did not observe",
  never "spend somebody else made".
  """
  @spec observation_complete?(map()) :: boolean()
  def observation_complete?(%{observed_from: %DateTime{} = from, window_started_at: %DateTime{} = start}),
    do: DateTime.compare(from, start) != :gt

  def observation_complete?(_budget), do: false

  @doc """
  When the remainder becomes attributable again, or `nil` when it already is.

  The meter's reach is fixed at its boot; the window's start advances only when
  the window resets. So a restart mid-window stays unattributable until that
  reset, and the reset is the actionable answer to "when can I trust this" —
  more use to an operator than a hedge, because it says whether to wait or to
  stop comparing.
  """
  @spec attributable_from(map()) :: DateTime.t() | nil
  def attributable_from(budget) do
    if observation_complete?(budget), do: nil, else: Map.get(budget, :window, %{})[:reset_at]
  end

  @doc "The budgets present in a sample, in `budget_order/0`, unknown ones last."
  @spec budgets(map() | nil) :: [{String.t(), map()}]
  def budgets(%{budgets: budgets}) when is_map(budgets) do
    known = Enum.flat_map(@budget_order, fn r -> for {^r, b} <- budgets, do: {r, b} end)
    rest = budgets |> Enum.reject(fn {r, _b} -> r in @budget_order end) |> Enum.sort_by(&elem(&1, 0))
    known ++ rest
  end

  def budgets(_sample), do: []

  @doc """
  The stacked series for one budget, or `nil` when there is nothing honest to
  draw.

  Bands are ordered bottom-up: the highest-spending named callers first, the
  folded tail above them, and `:outside` — spend this daemon did not issue — on
  top, so the top of the stack is the credential's own `used` figure and the
  chart reconciles by construction.

  Band identity is ranked once over the whole retained series rather than
  per-sample, so a caller keeps its colour when another overtakes it. Colour
  follows the caller, never its rank at one instant.

  The retained ring may cross a credential reset. The projection keeps those
  older points for comparison and carries the current window's start so the
  renderer can distinguish them from the current-window headline and table.
  """
  @spec series([map()], String.t()) :: map() | nil
  def series(samples, budget) when is_list(samples) and is_binary(budget) do
    present = Enum.flat_map(samples, &for({t, b} <- [point(&1, budget)], t != nil, do: {t, b}))
    {drawn, dropped} = trailing_observed(present)

    if length(drawn) >= 2 do
      {_t, latest} = List.last(drawn)
      current_window_started_at_ms = window_started_at_ms(latest)

      # Unlike the table, the legend describes the whole retained span. It may
      # name another consumer only when the meter covered every window drawn.
      bands = bands(drawn, Enum.all?(drawn, fn {_t, projection} -> observation_complete?(projection) end))

      %{
        budget: budget,
        scope: :bill,
        bands: bands,
        points: Enum.map(drawn, fn {t_ms, b} -> plot_point(t_ms, b, bands) end),
        dropped: dropped,
        estimated?: Enum.any?(drawn, fn {_t, b} -> b.estimated? end),
        current_window_started_at_ms: current_window_started_at_ms
      }
    end
  end

  def series(_samples, _budget), do: nil

  @doc "Whether a series retains samples from before its current credential window."
  @spec spans_previous_window?(map() | nil) :: boolean()
  def spans_previous_window?(%{points: [%{t_ms: first_t_ms} | _], current_window_started_at_ms: boundary})
      when is_integer(boundary),
      do: first_t_ms < boundary

  def spans_previous_window?(_series), do: false

  @doc """
  The same series with the remainder band removed and rescaled to what this
  daemon issued.

  The full chart is the honest headline and it is also nearly unreadable: on a
  shared installation the remainder is most of the plot, so the caller bands
  collapse into a sliver at the baseline. This is the companion that lets the
  ranking be *seen* rather than only read off a table.

  It is a second chart rather than a second axis on the first. Two y-scales in
  one frame is the one chart mistake that reliably makes a reader compare two
  quantities that were never comparable, and here the whole subject is a
  quantity that does not add up to the other one. `scope: :attributed` is
  carried so the rendering cannot label it as the bill by accident.
  """
  @spec attributed_only(map() | nil) :: map() | nil
  def attributed_only(%{bands: bands, points: points} = series) do
    kept = Enum.reject(bands, &(&1.kind == :outside))
    dropped_keys = bands -- kept

    if kept == [] do
      nil
    else
      %{
        series
        | scope: :attributed,
          bands: kept,
          points: Enum.map(points, &%{&1 | values: Map.drop(&1.values, Enum.map(dropped_keys, fn band -> band.key end))})
      }
    end
  end

  def attributed_only(_series), do: nil

  @doc """
  The ranked caller rows for one budget's projection, highest points first.

  Ties break on calls and then name so the order is total: an operator watching
  the table refresh should not see two equal rows swap places.
  """
  @spec ranked_callers(map()) :: [map()]
  def ranked_callers(%{callers: callers}) when is_list(callers),
    do: Enum.sort_by(callers, &{-&1.points, -&1.calls, &1.caller})

  def ranked_callers(_budget), do: []

  @doc """
  A caller's share of the *attributed* total, or `nil` when nothing was
  attributed.

  Share is of attributed and is labelled as such wherever it is drawn. Sharing
  out of the window's real spend would read as coverage, which is a much
  stronger claim than this number supports.
  """
  @spec share_of_attributed(map(), map()) :: float() | nil
  def share_of_attributed(_caller, %{attributed: total}) when not is_integer(total) or total <= 0, do: nil
  def share_of_attributed(%{points: points}, %{attributed: total}), do: Float.round(points / total, 4)
  def share_of_attributed(_caller, _budget), do: nil

  # -- internals ------------------------------------------------------------

  defp budget(snapshot, resource, window) do
    callers =
      snapshot
      |> Map.get(:callers, [])
      |> Enum.filter(&(Map.get(&1, :resource) == resource))
      |> Enum.map(&caller_row/1)

    coverage = snapshot |> Map.get(:coverage, %{}) |> Map.get(:resources, %{}) |> Map.get(resource, %{})
    reconciliation = snapshot |> Map.get(:reconciliation, %{}) |> Map.get(resource, %{})

    attributed = Enum.reduce(callers, 0, &(&1.points + &2))
    spend = Map.get(coverage, :spend)

    %{
      resource: resource,
      callers: callers,
      attributed: attributed,
      # `spend` is `limit - remaining` from the credential's own window, and is
      # absent once that window's reset has passed. Coverage already applies
      # that rule, so it is read rather than recomputed here.
      spend: spend,
      outside: outside(spend, attributed),
      direction: Map.get(reconciliation, :direction),
      estimated?: Enum.any?(callers, & &1.estimated?),
      # How far back the meter can see, against when this window opened. The
      # page prints both rather than only their comparison, because "observed
      # since 06:38, window opened 06:14" tells an operator what to do and a
      # softened sentence does not.
      observed_from: Map.get(snapshot, :observing_since),
      window_started_at: Map.get(window, :started_at),
      window: Map.take(window, [:limit, :remaining, :used, :reset_at])
    }
  end

  defp caller_row(caller) do
    %{
      caller: to_string(Map.get(caller, :caller) || "unattributed"),
      points: nonneg(Map.get(caller, :points)),
      calls: nonneg(Map.get(caller, :calls)),
      points_per_hour: Map.get(caller, :points_per_hour),
      estimated?: Map.get(caller, :estimated?, false) == true
    }
  end

  defp nonneg(value) when is_integer(value) and value >= 0, do: value
  defp nonneg(_value), do: 0

  # A window that reports less spend than this daemon attributed is a double
  # count, not a negative remainder. Clamping keeps the band from inverting the
  # stack; `direction: :excess` from the reconciliation is what says so out loud.
  defp outside(spend, attributed) when is_integer(spend) and is_integer(attributed), do: max(spend - attributed, 0)
  defp outside(_spend, _attributed), do: nil

  defp point(%{t_ms: t_ms, budgets: budgets}, budget) when is_map(budgets) do
    case Map.fetch(budgets, budget) do
      {:ok, projection} -> {t_ms, projection}
      :error -> {nil, nil}
    end
  end

  defp point(_sample, _budget), do: {nil, nil}

  defp window_started_at_ms(%{window_started_at: %DateTime{} = started_at}),
    do: DateTime.to_unix(started_at, :millisecond)

  defp window_started_at_ms(_budget), do: nil

  # Only the trailing run where the credential's window was observed is drawn.
  # A gap means `limit - remaining` described a window that had already closed,
  # and joining a line across it would draw a remainder nobody measured.
  defp trailing_observed(points) do
    drawn =
      points
      |> Enum.reverse()
      |> Enum.take_while(fn {_t, b} -> is_integer(b.spend) end)
      |> Enum.reverse()

    {drawn, length(points) - length(drawn)}
  end

  defp bands(drawn, observed_whole_window?) do
    totals =
      drawn
      |> Enum.flat_map(fn {_t, b} -> Enum.map(b.callers, &{&1.caller, &1.points}) end)
      |> Enum.reduce(%{}, fn {caller, points}, acc -> Map.update(acc, caller, points, &(&1 + points)) end)

    ranked = totals |> Enum.sort_by(fn {caller, points} -> {-points, caller} end) |> Enum.map(&elem(&1, 0))
    {named, folded} = Enum.split(ranked, @top_callers)

    caller_bands =
      named
      |> Enum.with_index(1)
      |> Enum.map(fn {caller, slot} -> %{key: caller, label: caller, kind: :caller, slot: slot} end)

    other_band =
      if folded == [],
        do: [],
        else: [%{key: "__other__", label: other_label(length(folded)), kind: :other, slot: nil}]

    caller_bands ++
      other_band ++
      [%{key: "__outside__", label: outside_label(observed_whole_window?), kind: :outside, slot: nil}]
  end

  @doc """
  What the remainder band may be called.

  Only a meter that was running when the window opened may name somebody else.
  Anything less says what is actually true — that this daemon did not see the
  spend — and leaves who made it open, because it does not know.
  """
  @spec outside_label(boolean()) :: String.t()
  def outside_label(true), do: "not issued by this daemon"
  def outside_label(_incomplete), do: "not observed by this daemon"

  defp other_label(1), do: "1 other caller"
  defp other_label(count), do: "#{count} other callers"

  defp plot_point(t_ms, projection, bands) do
    by_caller = Map.new(projection.callers, &{&1.caller, &1.points})
    named = for %{kind: :caller, key: key} <- bands, do: key

    values =
      Map.new(bands, fn
        %{key: key, kind: :caller} -> {key, Map.get(by_caller, key, 0)}
        %{key: key, kind: :other} -> {key, projection.attributed - Enum.reduce(named, 0, &(Map.get(by_caller, &1, 0) + &2))}
        %{key: key, kind: :outside} -> {key, projection.outside || 0}
      end)

    %{t_ms: t_ms, values: values, attributed: projection.attributed, spend: projection.spend}
  end
end
