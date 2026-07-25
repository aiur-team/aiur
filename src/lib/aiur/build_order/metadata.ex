defmodule Aiur.BuildOrder.Metadata do
  @moduledoc "Strict, presentation-safe Build Order planning metadata."

  alias Aiur.BuildOrder.Diagnostic

  @lanes ~w(plan-graph runtime dashboard-ui accounting platform)
  @max_labels 100

  @type complexity :: 1..5 | :unknown
  @type phase :: pos_integer() | :unphased
  @type lane :: String.t() | :unassigned
  @type t :: %__MODULE__{
          complexity: complexity(),
          phase: phase(),
          lane: lane(),
          warnings: [Diagnostic.t()]
        }

  defstruct complexity: :unknown, phase: :unphased, lane: :unassigned, warnings: []

  @spec parse(term()) :: t()
  def parse(labels) do
    {labels, warnings} = bounded_labels(labels)

    complexity =
      parse_dimension(
        labels,
        "complexity:",
        &parse_complexity/1,
        :unknown,
        :missing_complexity,
        :invalid_complexity,
        :ambiguous_complexity
      )

    phase =
      parse_dimension(
        labels,
        "phase:",
        &parse_phase/1,
        :unphased,
        :missing_phase,
        :invalid_phase,
        :ambiguous_phase
      )

    lane =
      parse_dimension(
        labels,
        "build-lane:",
        &parse_lane/1,
        :unassigned,
        :missing_lane,
        :invalid_lane,
        :ambiguous_lane
      )

    %__MODULE__{
      complexity: complexity.value,
      phase: phase.value,
      lane: lane.value,
      warnings: warnings ++ complexity.warnings ++ phase.warnings ++ lane.warnings
    }
  end

  @spec lanes() :: [String.t()]
  def lanes, do: @lanes

  defp bounded_labels(labels) when is_list(labels) do
    {labels, overflow} = Enum.split(labels, @max_labels)
    {valid, invalid} = Enum.split_with(labels, &valid_label?/1)
    warnings = overflow_warning(overflow) ++ invalid_warning(invalid)
    {Enum.map(valid, &(String.trim(&1) |> String.downcase())), warnings}
  end

  defp bounded_labels(_labels), do: {[], [Diagnostic.new(:labels_overflow)]}

  defp valid_label?(label),
    do: is_binary(label) and String.valid?(label) and byte_size(label) in 1..256

  defp overflow_warning([]), do: []
  defp overflow_warning(_overflow), do: [Diagnostic.new(:labels_overflow)]
  defp invalid_warning([]), do: []
  defp invalid_warning(_invalid), do: [Diagnostic.new(:invalid_label)]

  defp parse_dimension(labels, prefix, parser, fallback, missing, invalid, ambiguous) do
    candidates = Enum.filter(labels, &String.starts_with?(&1, prefix))
    parsed = Enum.map(candidates, parser)

    case {candidates, parsed} do
      {[], _} -> result(fallback, missing)
      {[_], [{:ok, value}]} -> %{value: value, warnings: []}
      {[_], _} -> result(fallback, invalid)
      _ -> result(fallback, ambiguous)
    end
  end

  defp result(value, warning), do: %{value: value, warnings: [Diagnostic.new(warning)]}
  defp parse_complexity("complexity:" <> <<level>>) when level in ?1..?5, do: {:ok, level - ?0}
  defp parse_complexity(_label), do: :error

  defp parse_phase("phase:" <> value) do
    if Regex.match?(~r/^[1-9][0-9]{0,18}$/, value),
      do: {:ok, String.to_integer(value)},
      else: :error
  end

  defp parse_phase(_label), do: :error
  # Accept any well-formed lane slug, not only the built-in `@lanes`. Lanes are
  # a planner's choice (the dashboard renders a column per distinct lane and
  # falls back to a generic icon for unknown ones), so a build order may define
  # its own epics. `@lanes`/`lanes/0` still name the built-ins for ordering.
  defp parse_lane("build-lane:" <> lane) do
    if valid_lane_slug?(lane), do: {:ok, lane}, else: :error
  end

  defp parse_lane(_label), do: :error

  defp valid_lane_slug?(lane), do: Regex.match?(~r/^[a-z0-9][a-z0-9-]{0,63}$/, lane)
end
