defmodule Aiur.Agent.UsageSnapshot do
  @moduledoc """
  Per-agent cumulative usage snapshot with explicit unknown handling.

  This struct models a point-in-time view of an agent's lifetime token consumption,
  separate from current context occupancy (active working set). All unknown or
  unsupported dimensions are represented as `{:unknown, reason}` tuples rather
  than zeros or nils, preserving measurement gaps for explicit display and analysis.

  Scope identifies the aggregation level (session, attempt, or ticket) and the
  scope_id identifies which session/attempt/ticket the metrics cover. Freshness
  assessment helps operators understand data staleness.
  """

  defstruct [
    :agent_id,
    :backend,
    :context_occupancy,
    :cumulative_metrics,
    :scope,
    :scope_id,
    :observed_at,
    :freshness_assessment
  ]

  @type token_value :: non_neg_integer() | {:unknown, atom()}

  @type context_occupancy :: %{
          used_tokens: non_neg_integer(),
          window_tokens: non_neg_integer() | nil,
          pressure: atom() | nil
        }

  @type cumulative_metrics :: %{
          input: token_value(),
          output: token_value(),
          cached_input: token_value(),
          uncached_input: token_value(),
          cached_proportion: float() | {:unknown, atom()}
        }

  @type scope :: :session | :attempt | :ticket

  @type freshness :: :current | :stale | :unknown

  @type t :: %__MODULE__{
          agent_id: String.t(),
          backend: atom() | String.t(),
          context_occupancy: context_occupancy() | nil,
          cumulative_metrics: cumulative_metrics(),
          scope: scope(),
          scope_id: String.t(),
          observed_at: DateTime.t() | nil,
          freshness_assessment: freshness()
        }

  @doc """
  Calculate cached proportion as a float between 0.0 and 1.0.

  Returns cached_input / (input + cached_input) when both are known and positive.
  Returns {:unknown, reason} for edge cases:
  - :missing_input if input is unknown
  - :missing_cached_input if cached_input is unknown
  - :zero_input if input is zero (cannot divide)
  - :zero_cached_input if cached_input is zero (proportion is 0.0)
  """
  @spec calculate_cached_proportion(token_value(), token_value()) :: float() | {:unknown, atom()}
  def calculate_cached_proportion(input, cached_input)

  def calculate_cached_proportion({:unknown, _}, _cached_input) do
    {:unknown, :missing_input}
  end

  def calculate_cached_proportion(_input, {:unknown, _}) do
    {:unknown, :missing_cached_input}
  end

  def calculate_cached_proportion(input, cached_input)
      when is_integer(input) and is_integer(cached_input) and input >= 0 and cached_input >= 0 do
    # cached_proportion = cached_input / input
    # Validate: cached_input cannot be greater than total input
    cond do
      cached_input > input ->
        {:unknown, :invalid_token_values}

      input == 0 ->
        {:unknown, :zero_input}

      true ->
        cached_input / input
    end
  end

  def calculate_cached_proportion(input, cached_input) when is_integer(input) or is_integer(cached_input) do
    {:unknown, :invalid_token_values}
  end

  @doc """
  Format a token value for display.

  Known integers are formatted as-is. Unknown values return "—".
  """
  @spec format_token_dimension(token_value()) :: String.t()
  def format_token_dimension({:unknown, _}), do: "—"

  def format_token_dimension(n) when is_integer(n) and n >= 0 do
    Integer.to_string(n)
  end

  def format_token_dimension(_), do: "—"

  @doc """
  Format cached proportion as a percentage string.

  Known floats return "XX.X%". Unknown values return "—".
  """
  @spec format_cached_proportion(float() | {:unknown, atom()}) :: String.t()
  def format_cached_proportion({:unknown, _}), do: "—"

  def format_cached_proportion(proportion) when is_float(proportion) and proportion >= 0.0 and proportion <= 1.0 do
    percent = proportion * 100
    :erlang.float_to_binary(percent, decimals: 1) <> "%"
  end

  def format_cached_proportion(_), do: "—"

  @doc """
  Assess freshness based on observation timestamp.

  - :current if within 5 minutes
  - :stale if 5 minutes to 1 hour
  - :stale if older than 1 hour
  - :unknown if observed_at is nil
  """
  @spec assess_freshness(DateTime.t() | nil) :: freshness()
  def assess_freshness(nil), do: :unknown

  def assess_freshness(observed_at) do
    now = DateTime.utc_now()

    case DateTime.diff(now, observed_at, :second) do
      # < 5 minutes
      diff when diff < 300 -> :current
      # >= 5 minutes
      _diff -> :stale
    end
  end

  @doc """
  Format freshness assessment as a human-readable string.

  Handles :current, :stale, and :unknown.
  """
  @spec format_freshness(freshness(), DateTime.t() | nil) :: String.t()
  def format_freshness(:unknown, _), do: "unknown freshness"

  def format_freshness(:current, observed_at) when not is_nil(observed_at) do
    format_age(observed_at)
  end

  def format_freshness(:stale, observed_at) when not is_nil(observed_at) do
    format_age(observed_at) <> " (stale)"
  end

  def format_freshness(_, nil), do: "unknown freshness"
  def format_freshness(_, _), do: "unknown freshness"

  # Helper to format age in minutes/hours
  defp format_age(timestamp) do
    now = DateTime.utc_now()
    seconds_ago = DateTime.diff(now, timestamp, :second)

    cond do
      seconds_ago < 60 ->
        "#{seconds_ago}s ago"

      seconds_ago < 3600 ->
        minutes = div(seconds_ago, 60)
        "#{minutes}m ago"

      true ->
        hours = div(seconds_ago, 3600)
        "#{hours}h ago"
    end
  end
end
