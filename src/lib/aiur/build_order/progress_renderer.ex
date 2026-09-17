defmodule Aiur.BuildOrder.ProgressRenderer do
  @moduledoc """
  The only presentation boundary for Build Order completion resolution.

  Callers provide the `RootSummary` contract shape (a struct or map containing
  `progress`, `progress_resolution`, `progress_resolved_count`, and optionally
  `member_count`). Each output medium gets one projection function. Missing,
  malformed, or internally inconsistent values fail closed to `:unknown`, so a
  legacy percentage can never look resolved merely because it is an integer.

  Grid completion values may also carry `stale_count` and `stale_observed_at`:
  how many resolved members contribute a *last-known* activity reading rather
  than a live one or an accepted lifecycle completion, and the oldest such
  reading. Every projection surfaces that as a last-known marker with its age
  (relative to the `:now` option, defaulting to the current time) so retained
  work stays visible without posing as current. Values without those fields
  (catalog roots, whose completion is lifecycle-derived) render unchanged.
  """

  alias Aiur.BuildOrder.RootSummary

  @type last_known :: %{count: pos_integer(), observed_at: DateTime.t() | nil, age: String.t()} | nil

  @type html_projection :: %{
          state: RootSummary.progress_resolution() | :empty,
          label: String.t(),
          percent: 0..100 | nil,
          coverage: String.t() | nil,
          freshness: :current | :last_known,
          note: String.t() | nil,
          aria_label: String.t(),
          title: String.t()
        }

  @doc "Projects completion resolution into terminal text."
  @spec terminal(term(), keyword()) :: String.t()
  def terminal(value, opts \\ []) do
    projection = project(value, opts)

    base =
      case projection do
        %{state: :resolved, percent: percent} -> "#{percent}%"
        %{state: :partial, percent: percent, coverage: nil} -> "#{percent}% partial"
        %{state: :partial, percent: percent, coverage: coverage} -> "#{percent}% partial (#{coverage})"
        %{state: :empty} -> "empty"
        %{state: :unresolved} -> "unresolved"
        %{state: :unknown} -> "unknown"
      end

    case projection.last_known do
      nil -> base
      last_known -> "#{base} (#{last_known_note(last_known)})"
    end
  end

  @doc """
  Projects completion resolution into a stable JSON object.

  `progress_stale_count` and `progress_stale_observed_at` are present only when
  the value carries last-known evidence at all (a `stale_count` field), so a
  lifecycle-derived catalog root keeps its three-field object.
  """
  @spec json(term()) :: %{required(String.t()) => String.t() | non_neg_integer() | nil}
  def json(value) do
    projection = project(value, [])

    base = %{
      "progress" => projection.percent,
      "progress_resolution" => Atom.to_string(projection.state),
      "progress_resolved_count" => projection.resolved_count
    }

    case projection.stale_count do
      nil ->
        base

      stale_count ->
        Map.merge(base, %{
          "progress_stale_count" => stale_count,
          "progress_stale_observed_at" => projection.stale_observed_at && DateTime.to_iso8601(projection.stale_observed_at)
        })
    end
  end

  @doc "Projects completion resolution into values safe for an HTML surface."
  @spec html(term(), keyword()) :: html_projection()
  def html(value, opts \\ []) do
    projection = project(value, opts)
    state = projection.state

    %{
      state: state,
      label: html_label(projection),
      percent: projection.percent,
      coverage: projection.coverage,
      freshness: if(projection.last_known, do: :last_known, else: :current),
      note: projection.last_known && last_known_note(projection.last_known),
      aria_label: aria_label(projection),
      title: title(projection)
    }
  end

  defp project(value, opts) when is_map(value) do
    progress = value |> field(:progress) |> percent()
    resolved_count = value |> field(:progress_resolved_count) |> count()
    member_count = value |> field(:member_count) |> count()
    resolution = resolution(field(value, :progress_resolution))
    # The grid contract names these `stale_count` / `stale_observed_at`; the
    # JSON projection republishes them as `progress_stale_*`, and the CLI's
    # human output reprints that JSON object, so both spellings are read.
    stale_count = (field(value, :stale_count) || field(value, :progress_stale_count)) |> count()
    stale_observed_at = field(value, :stale_observed_at) || field(value, :progress_stale_observed_at)

    projection =
      if consistent?(resolution, resolved_count, member_count) do
        project_resolution(resolution, progress, resolved_count, member_count)
      else
        projection(:unknown, nil, nil, member_count)
      end

    projection
    |> Map.put(:stale_count, stale_count)
    |> Map.put(:stale_observed_at, datetime(stale_observed_at))
    |> Map.put(:last_known, last_known(projection, stale_count, stale_observed_at, opts))
  end

  defp project(_value, _opts), do: projection(:unknown, nil, nil, nil) |> Map.merge(%{stale_count: nil, stale_observed_at: nil, last_known: nil})

  # A last-known marker only qualifies a percentage that is actually shown; an
  # unresolved or unknown projection has no percent for retained work to bias.
  defp last_known(%{state: state, percent: percent}, stale_count, observed_at, opts)
       when state in [:resolved, :partial] and is_integer(percent) and is_integer(stale_count) and stale_count > 0 do
    observed_at = datetime(observed_at)
    %{count: stale_count, observed_at: observed_at, age: relative_age(observed_at, Keyword.get(opts, :now))}
  end

  defp last_known(_projection, _stale_count, _observed_at, _opts), do: nil

  defp last_known_note(%{count: 1, age: age}), do: "last known #{age}"
  defp last_known_note(%{count: count, age: age}), do: "#{count} last known, oldest #{age}"

  defp datetime(%DateTime{} = value), do: value

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> parsed
      _error -> nil
    end
  end

  defp datetime(_value), do: nil

  defp relative_age(nil, _now), do: "age unknown"

  defp relative_age(%DateTime{} = observed_at, now) do
    now = if is_struct(now, DateTime), do: now, else: DateTime.utc_now()
    diff = DateTime.diff(now, observed_at, :second)

    cond do
      diff <= 60 -> "just now"
      diff < 3_600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3_600)}h ago"
      true -> "#{div(diff, 86_400)}d ago"
    end
  end

  defp project_resolution(:empty, _progress, resolved_count, member_count),
    do: projection(:empty, nil, resolved_count, member_count)

  defp project_resolution(:resolved, progress, resolved_count, 0) when is_integer(progress),
    do: projection(:empty, nil, resolved_count, 0)

  defp project_resolution(:resolved, progress, resolved_count, member_count) when is_integer(progress),
    do: projection(:resolved, progress, resolved_count, member_count)

  defp project_resolution(:partial, progress, resolved_count, member_count) when is_integer(progress),
    do: projection(:partial, progress, resolved_count, member_count)

  defp project_resolution(:unresolved, _progress, resolved_count, member_count),
    do: projection(:unresolved, nil, resolved_count, member_count)

  defp project_resolution(_resolution, _progress, _resolved_count, member_count),
    do: projection(:unknown, nil, nil, member_count)

  defp projection(state, percent, resolved_count, member_count) do
    %{
      state: state,
      percent: percent,
      resolved_count: resolved_count,
      member_count: member_count,
      coverage: coverage(state, resolved_count, member_count)
    }
  end

  defp field(value, key) do
    case Map.fetch(value, key) do
      {:ok, field_value} -> field_value
      :error -> Map.get(value, Atom.to_string(key))
    end
  end

  defp resolution(value) when value in [:resolved, "resolved"], do: :resolved
  defp resolution(value) when value in [:partial, "partial"], do: :partial
  defp resolution(value) when value in [:empty, "empty"], do: :empty
  defp resolution(value) when value in [:unresolved, "unresolved"], do: :unresolved
  defp resolution(value) when value in [:unknown, "unknown"], do: :unknown
  defp resolution(_value), do: :unknown

  defp percent(value) when is_integer(value) and value in 0..100, do: value
  defp percent(_value), do: nil

  defp count(value) when is_integer(value) and value >= 0, do: value
  defp count(_value), do: nil

  # Counts are optional evidence, but when both are available they must agree
  # with the declared resolution. A contradictory explicit state is less useful
  # than an honest unknown: it must not gain confidence merely because its
  # percentage looks plausible.
  defp consistent?(:resolved, resolved_count, member_count)
       when is_integer(resolved_count) and is_integer(member_count),
       do: resolved_count == member_count

  defp consistent?(:partial, resolved_count, member_count)
       when is_integer(resolved_count) and is_integer(member_count),
       do: resolved_count > 0 and resolved_count < member_count

  defp consistent?(:partial, resolved_count, nil) when is_integer(resolved_count),
    do: resolved_count > 0

  defp consistent?(:empty, resolved_count, member_count),
    do: resolved_count == 0 and member_count == 0

  defp consistent?(:unresolved, resolved_count, _member_count) when is_integer(resolved_count),
    do: resolved_count == 0

  defp consistent?(_state, _resolved_count, _member_count), do: true

  defp coverage(:partial, resolved_count, member_count)
       when is_integer(resolved_count) and is_integer(member_count),
       do: "#{resolved_count}/#{member_count} resolved"

  defp coverage(:partial, resolved_count, _member_count) when is_integer(resolved_count),
    do: "#{resolved_count} resolved"

  defp coverage(_state, _resolved_count, _member_count), do: nil

  defp html_label(%{state: :resolved, percent: percent}), do: "#{percent}%"
  defp html_label(%{state: :partial, percent: percent}), do: "#{percent}% partial"
  defp html_label(%{state: :empty}), do: "Empty"
  defp html_label(%{state: :unresolved}), do: "unresolved"
  defp html_label(%{state: :unknown}), do: "unknown"

  defp aria_label(%{last_known: %{} = last_known} = projection),
    do: "#{aria_label(%{projection | last_known: nil})}; #{last_known_note(last_known)}"

  defp aria_label(%{state: :resolved, percent: percent}),
    do: "#{percent}% complete; completion fully resolved"

  defp aria_label(%{state: :partial, percent: percent, coverage: nil}),
    do: "#{percent}% complete with partial resolution; coverage unavailable"

  defp aria_label(%{state: :partial, percent: percent, coverage: coverage}),
    do: "#{percent}% complete with partial resolution; #{coverage}"

  defp aria_label(%{state: :empty}), do: "Empty Build Order; no members"

  defp aria_label(%{state: :unresolved}),
    do: "Progress unresolved; completion could not be resolved"

  defp aria_label(%{state: :unknown}),
    do: "Progress unknown; no resolution information was provided"

  # The wording is about the progress reading, not the agent: an activity row
  # can be fresh while its progress field is the stale part.
  defp title(%{last_known: %{count: 1, age: age}} = projection),
    do: "#{title(%{projection | last_known: nil})} One member counts the progress last observed #{age}; no newer progress reading has been observed."

  defp title(%{last_known: %{count: count, age: age}} = projection),
    do: "#{title(%{projection | last_known: nil})} #{count} members count the progress last observed for each (oldest #{age}); no newer progress reading has been observed for them."

  defp title(%{state: :resolved}), do: "Completion is resolved for every member."

  defp title(%{state: :partial, coverage: nil}),
    do: "Completion is resolved for only part of this Build Order; coverage is unavailable."

  defp title(%{state: :partial, coverage: coverage}),
    do: "Completion is resolved for only part of this Build Order: #{coverage}."

  defp title(%{state: :empty}), do: "This Build Order has no members."

  defp title(%{state: :unresolved}),
    do: "Completion resolution was attempted but could not resolve any progress."

  defp title(%{state: :unknown}),
    do: "No completion resolution information is available."
end
