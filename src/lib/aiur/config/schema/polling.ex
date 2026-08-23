defmodule Aiur.Config.Schema.Polling do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @min_usage_interval_seconds 120
  @max_idle_widen_factor 100.0

  # Mirrored from `Aiur.PollCadence.poll_classes/0`. Kept local here so the
  # schema does not reference `PollCadence` (which references `Aiur.Config`,
  # which embeds this schema — a compile cycle). A test asserts the two stay in
  # sync.
  @known_poll_classes ["dispatch", "ci", "review", "planning", "firehose"]

  @primary_key false
  embedded_schema do
    # The tracker sweep and the repo-events firehose share this tick, so the
    # GitHub GraphQL spend of polling scales as 1/interval. Measured against a
    # 5,000 point/hour budget: 30s costs roughly 5,800 points/hour on its own —
    # more than the entire budget before a single agent runs — while 60s costs
    # ~2,900 and 120s ~1,450. Widening past 120s buys progressively less (300s
    # saves only another ~870) for a proportionally worse worst-case wake.
    # 120s keeps the whole poll component under a third of the budget and stays
    # far inside the Executor's 15-minute sweep.
    #
    # Those costs assume the interval is the one actually used. GitHub's
    # `X-Poll-Interval` (60s by default) is a competing floor, and
    # `TrackerHealth.next_poll_delay_ms/1` takes the wider of the two — so a
    # value under 60 mostly does not tighten the loop, and the real saving from
    # this 120s default is measured against an effective 60s, not against 30s.
    field(:interval_seconds, :integer, default: 120)
    # With no agent actively running, reconciliation is housekeeping rather
    # than an input to active work. Operator and webhook wakes still schedule
    # an immediate fresh sweep before new work is admitted.
    field(:idle_widen_factor, :float, default: 5.0)
    # Usage endpoint allows ~1 request/2min, per account. Measured floor 120s.
    field(:usage_interval_seconds, :integer, default: 300)
    # The single view-state reconciliation sweep. It exists only to recover a
    # webhook delivery that was lost — measured at 9 of 100 during a restart,
    # with no GitHub retry and no late arrival — so it is a recovery bound, not a
    # freshness knob: a delivery that arrives is already free and instant, and
    # shortening this makes nothing fresher. 15 minutes bounds the worst-case
    # blind spot to well inside an operator's attention span while costing a
    # fraction of what the three per-source cadences it replaced did.
    field(:view_state_sweep_seconds, :integer, default: 900)
    # Per-class poll cadences, in seconds, for the state classes Aiur polls.
    # Each entry names a poll class (`dispatch`, `ci`, `review`, `planning`,
    # `firehose`); a class with no entry uses `interval_seconds`. The map is
    # optional, so existing configs that only set `interval_seconds` keep
    # exactly today's behaviour (every class shares the single value). See
    # `Aiur.PollCadence` for how each class resolves and is consumed.
    field(:intervals, {:map, :integer}, default: %{})
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    if Map.has_key?(attrs, "interval_ms") or Map.has_key?(attrs, :interval_ms) do
      raise ArgumentError,
            "polling.interval_ms is no longer supported; rename to interval_seconds " <>
              "(value in seconds, not milliseconds)"
    end

    schema
    |> cast(attrs, [:interval_seconds, :idle_widen_factor, :usage_interval_seconds, :view_state_sweep_seconds, :intervals], empty_values: [])
    |> validate_number(:interval_seconds, greater_than: 0)
    |> validate_number(:view_state_sweep_seconds, greater_than: 0)
    |> validate_number(:idle_widen_factor,
      greater_than_or_equal_to: 1.0,
      less_than_or_equal_to: @max_idle_widen_factor,
      message: "must be between 1.0 and #{@max_idle_widen_factor}"
    )
    # Below the floor the meters degrade silently, so fail loudly instead.
    |> validate_number(:usage_interval_seconds,
      greater_than_or_equal_to: @min_usage_interval_seconds,
      message: "must be at least #{@min_usage_interval_seconds} seconds; the provider usage endpoint allows about one request every two minutes and rejects the rest"
    )
    # A typo'd class name (or a class that does not exist) silently falls back
    # to `interval_seconds`, which is exactly how an operator would lose the
    # divergence they asked for — so an unknown key fails loudly instead.
    |> validate_change(:intervals, &validate_intervals/2)
  end

  # String keys, because `{:map, :integer}` casts keep the YAML keys verbatim.
  defp validate_intervals(:intervals, intervals) when is_map(intervals) do
    known = MapSet.new(@known_poll_classes)

    Enum.flat_map(intervals, fn {class, seconds} ->
      cond do
        not MapSet.member?(known, class) ->
          [{:intervals, "unknown poll class #{inspect(class)}; expected one of #{@known_poll_classes |> Enum.sort() |> Enum.join(", ")}"}]

        not (is_integer(seconds) and seconds > 0) ->
          [{:intervals, "interval for #{class} must be a positive integer (seconds), got: #{inspect(seconds)}"}]

        true ->
          []
      end
    end)
  end

  defp validate_intervals(:intervals, _invalid), do: []
end
