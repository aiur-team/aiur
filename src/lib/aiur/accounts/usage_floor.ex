defmodule Aiur.Accounts.UsageFloor do
  @moduledoc """
  Pure decision for the remaining-usage floor (#7504).

  `agent.usage_floor_percent` (default `5`) tells dispatch to stop *starting*
  work on a route whose freshest reading shows that little left. This module
  owns only the per-reading decision and its operator-facing text: callers pass
  a reading and the floor that applies to its backend, and get either `:allow`
  or the held window that floored it. It reads no config, no process state and
  no files, so the rule can be asserted directly.

  ## Which readings floor a route

  A reading is the headroom reading shape: `:windows` maps a window name to the
  percent already used, `:resets` carries that window's reset time when the
  source knows it. A route is floored when **any** window is at or below the
  floor — a weekly window at 3% floors the route even while its 5-hour window
  has 80% left, because the operator's "nearly gone" means the tightest window,
  not the roomiest one.

  Three readings never floor anything, deliberately:

    * **unknown** (no reading, no numeric window, or no known limit) — aiur must
      not invent a shortage it never observed;
    * **stale** — an old number cannot justify moving work, and dispatch already
      scores it as unknown (#5747);
    * **limited** — the existing availability gate already refuses an exhausted
      route, so the floor stays out of its way.

  `0` (and `nil`) disables the floor: every reading is allowed.
  """

  @default_percent 5

  @typedoc "A window's reset time, when the reading's source knows it."
  @type resets :: %{optional(String.t()) => DateTime.t() | nil}

  @typedoc """
  The headroom reading shape. `:windows` is either a map of window name to used
  percent or the raw provider list of `%{window: name, used_percent: percent}`
  entries. `:resets` maps window name to its reset time. `stale: true` and
  `limited: true` are the two existing disqualifiers.
  """
  @type reading ::
          %{
            optional(:windows) => %{optional(String.t()) => number() | nil} | [map()],
            optional(:resets) => resets(),
            optional(:stale) => boolean(),
            optional(:limited) => boolean(),
            optional(:age_seconds) => non_neg_integer(),
            optional(:source) => String.t()
          }
          | nil

  @typedoc "The window that floored a route, with everything the held line needs."
  @type held :: %{
          window: String.t(),
          used_percent: number(),
          remaining_percent: number(),
          floor_percent: non_neg_integer(),
          resets_at: DateTime.t() | nil,
          age_seconds: non_neg_integer() | nil,
          source: String.t() | nil
        }

  @doc "The documented default floor: five percent remaining."
  @spec default_percent() :: pos_integer()
  def default_percent, do: @default_percent

  @doc "Whether a floor value switches the gate on. `0` (and `nil`) means off."
  @spec enabled?(term()) :: boolean()
  def enabled?(floor), do: is_integer(floor) and floor > 0

  @doc """
  Decide one reading against one floor.

  Returns `:allow` when the route may be dispatched, or `{:held, held}` naming
  the tightest window at or below the floor. See the module docs for the three
  readings that are always allowed.
  """
  @spec decision(reading(), term()) :: :allow | {:held, held()}
  def decision(_reading, floor) when not is_integer(floor) or floor <= 0, do: :allow

  def decision(reading, floor) when is_map(reading) do
    cond do
      Map.get(reading, :limited) == true -> :allow
      Map.get(reading, :stale) == true -> :allow
      true -> window_decision(windows(reading), resets(reading), floor, reading)
    end
  end

  def decision(_reading, _floor), do: :allow

  @doc "Whether a reading is floored at this floor."
  @spec held?(reading(), term()) :: boolean()
  def held?(reading, floor), do: match?({:held, _held}, decision(reading, floor))

  @doc """
  The operator-facing fragment for one held reading, e.g.
  `held: 3% left ≤ 5% floor, resets in 2h`. Callers prefix the route.
  """
  @spec held_line(held()) :: String.t()
  def held_line(%{} = held) do
    "held: #{percent_text(Map.get(held, :remaining_percent))}% left ≤ #{Map.get(held, :floor_percent)}% floor" <>
      reset_suffix(Map.get(held, :resets_at))
  end

  @doc "The percent a reading has left in its tightest window, or `nil` when unknown."
  @spec remaining_percent(reading()) :: number() | nil
  def remaining_percent(reading) when is_map(reading) do
    case windows(reading) do
      windows when map_size(windows) == 0 -> nil
      windows -> windows |> Enum.max_by(fn {_window, used} -> used end) |> elem(1) |> remaining()
    end
  end

  def remaining_percent(_reading), do: nil

  defp window_decision(windows, resets, floor, reading) when map_size(windows) > 0 do
    # The tightest window is the one with the most already used — the least
    # remaining — so a floored weekly window holds the route even while its
    # 5-hour window is comfortable.
    {window, used} = Enum.max_by(windows, fn {_window, used} -> used end)
    left = remaining(used)

    if left <= floor do
      {:held,
       %{
         window: window,
         used_percent: used,
         remaining_percent: left,
         floor_percent: floor,
         resets_at: Map.get(resets, window),
         age_seconds: Map.get(reading, :age_seconds),
         source: Map.get(reading, :source)
       }}
    else
      :allow
    end
  end

  defp window_decision(_windows, _resets, _floor, _reading), do: :allow

  # A reading's windows arrive in two shapes: the headroom reading's map of
  # window name to used percent, or the provider list of `%{window:, used_percent:}`
  # entries that `Aiur.Accounts.UsageReadings` records. A window without a
  # numeric used percent has no known limit and never floors anything.
  defp windows(%{windows: windows}) when is_map(windows) do
    for {window, used} <- windows, is_number(used), into: %{}, do: {to_string(window), used}
  end

  defp windows(%{windows: windows}) when is_list(windows) do
    for %{window: window, used_percent: used} <- windows, is_number(used), into: %{}, do: {to_string(window), used}
  end

  defp windows(_reading), do: %{}

  defp resets(%{resets: resets}) when is_map(resets), do: resets
  defp resets(_reading), do: %{}

  defp remaining(used), do: 100.0 - min(max(used, 0), 100)

  defp percent_text(percent) when is_number(percent) do
    rounded = Float.round(percent * 1.0, 1)
    if rounded == trunc(rounded), do: Integer.to_string(trunc(rounded)), else: to_string(rounded)
  end

  defp percent_text(_percent), do: "?"

  defp reset_suffix(%DateTime{} = resets_at) do
    case DateTime.diff(resets_at, DateTime.utc_now()) do
      seconds when seconds <= 0 -> ""
      seconds when seconds < 3_600 -> ", resets in #{div(seconds, 60)}m"
      seconds when seconds < 86_400 -> ", resets in #{div(seconds, 3_600)}h #{div(rem(seconds, 3_600), 60)}m"
      seconds -> ", resets in #{div(seconds, 86_400)}d #{div(rem(seconds, 86_400), 3_600)}h"
    end
  end

  defp reset_suffix(_resets_at), do: ""
end
