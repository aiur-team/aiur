defmodule Aiur.BuildOrder.ProgressRenderer do
  @moduledoc """
  The only presentation boundary for Build Order completion resolution.

  Callers provide the `RootSummary` contract shape (a struct or map containing
  `progress`, `progress_resolution`, `progress_resolved_count`, and optionally
  `member_count`). Each output medium gets one projection function. Missing,
  malformed, or internally inconsistent values fail closed to `:unknown`, so a
  legacy percentage can never look resolved merely because it is an integer.
  """

  alias Aiur.BuildOrder.RootSummary

  @type html_projection :: %{
          state: RootSummary.progress_resolution(),
          label: String.t(),
          percent: 0..100 | nil,
          coverage: String.t() | nil,
          aria_label: String.t(),
          title: String.t()
        }

  @doc "Projects completion resolution into terminal text."
  @spec terminal(term()) :: String.t()
  def terminal(value) do
    case project(value) do
      %{state: :resolved, percent: percent} -> "#{percent}%"
      %{state: :partial, percent: percent, coverage: nil} -> "#{percent}% partial"
      %{state: :partial, percent: percent, coverage: coverage} -> "#{percent}% partial (#{coverage})"
      %{state: :unresolved} -> "unresolved"
      %{state: :unknown} -> "unknown"
    end
  end

  @doc "Projects completion resolution into a stable JSON object."
  @spec json(term()) :: %{required(String.t()) => String.t() | non_neg_integer() | nil}
  def json(value) do
    projection = project(value)

    %{
      "progress" => projection.percent,
      "progress_resolution" => Atom.to_string(projection.state),
      "progress_resolved_count" => projection.resolved_count
    }
  end

  @doc "Projects completion resolution into values safe for an HTML surface."
  @spec html(term()) :: html_projection()
  def html(value) do
    projection = project(value)
    state = projection.state

    %{
      state: state,
      label: html_label(projection),
      percent: projection.percent,
      coverage: projection.coverage,
      aria_label: aria_label(projection),
      title: title(projection)
    }
  end

  defp project(value) when is_map(value) do
    progress = value |> field(:progress) |> percent()
    resolved_count = value |> field(:progress_resolved_count) |> count()
    member_count = value |> field(:member_count) |> count()
    resolution = resolution(field(value, :progress_resolution))

    if consistent?(resolution, resolved_count, member_count) do
      case resolution do
        :resolved when is_integer(progress) -> projection(:resolved, progress, resolved_count, member_count)
        :partial when is_integer(progress) -> projection(:partial, progress, resolved_count, member_count)
        :unresolved -> projection(:unresolved, nil, resolved_count, member_count)
        _unknown_or_invalid -> projection(:unknown, nil, nil, member_count)
      end
    else
      projection(:unknown, nil, nil, member_count)
    end
  end

  defp project(_value), do: projection(:unknown, nil, nil, nil)

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
  defp html_label(%{state: :unresolved}), do: "unresolved"
  defp html_label(%{state: :unknown}), do: "unknown"

  defp aria_label(%{state: :resolved, percent: percent}),
    do: "#{percent}% complete; completion fully resolved"

  defp aria_label(%{state: :partial, percent: percent, coverage: nil}),
    do: "#{percent}% complete with partial resolution; coverage unavailable"

  defp aria_label(%{state: :partial, percent: percent, coverage: coverage}),
    do: "#{percent}% complete with partial resolution; #{coverage}"

  defp aria_label(%{state: :unresolved}),
    do: "Progress unresolved; completion could not be resolved"

  defp aria_label(%{state: :unknown}),
    do: "Progress unknown; no resolution information was provided"

  defp title(%{state: :resolved}), do: "Completion is resolved for every member."

  defp title(%{state: :partial, coverage: nil}),
    do: "Completion is resolved for only part of this Build Order; coverage is unavailable."

  defp title(%{state: :partial, coverage: coverage}),
    do: "Completion is resolved for only part of this Build Order: #{coverage}."

  defp title(%{state: :unresolved}),
    do: "Completion resolution was attempted but could not resolve any progress."

  defp title(%{state: :unknown}),
    do: "No completion resolution information is available."
end
