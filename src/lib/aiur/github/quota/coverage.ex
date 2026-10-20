defmodule Aiur.GitHub.Quota.Coverage do
  @moduledoc false

  alias Aiur.GitHub.Quota.Attribution

  @unattributed "unattributed"
  # How far the per-caller breakdown may sit from what GitHub says the window
  # actually cost before it stops being evidence. Aiur cannot see calls made on
  # the credential outside this process, so a shortfall is expected; the margin
  # is what turns "roughly agrees" into a testable claim.
  @reconciliation_margin 0.05

  @doc """
  Does the per-caller breakdown add up to what GitHub says the window cost?

  A breakdown that does not reconcile is not evidence, it is a guess with a
  table around it. `spend` is `limit - remaining` from the credential's own
  `/rate_limit` window — the number the operator sees drop — and `attributed`
  is the sum of every row in the ranking. `reconciled?` is the claim that the
  two agree closely enough to act on.

  The two ways it can fail are not the same fact, so `direction` separates them:

    * `:shortfall` — Aiur attributed less than the window spent. This is the
      normal, expected case: calls made on the same credential by anything
      outside this process are real spend Aiur never saw. It bounds how much of
      the ranking is the whole story; it is not a defect.
    * `:excess` — Aiur attributed more than the window spent. Points cannot be
      counted twice, so this is a bug in the accounting and is the only case
      worth alarming on.
    * `:agrees` — inside the margin.

  Collapsing both into one boolean would print an alarm during normal operation,
  and an operator who learns to ignore the alarm cannot see the double count
  when it happens. `reconciled?` is kept for the inside-the-margin claim.
  """
  @spec reconciliation(map()) :: %{optional(String.t()) => map()}
  def reconciliation(%{resources: resources}) when is_map(resources) do
    Map.new(resources, fn {resource, figures} ->
      attributed = Map.get(figures, :attributed)
      spend = Map.get(figures, :spend)

      {resource,
       %{
         attributed: attributed,
         spend: spend,
         delta: delta(attributed, spend),
         margin: @reconciliation_margin,
         reconciled?: reconciled?(attributed, spend),
         direction: direction(attributed, spend),
         estimated?: Map.get(figures, :estimated?, false)
       }}
    end)
  end

  def reconciliation(_coverage), do: %{}

  defp delta(attributed, spend) when is_integer(attributed) and is_integer(spend), do: attributed - spend
  defp delta(_attributed, _spend), do: nil

  # Nothing spent is trivially reconciled; nothing observed is not reconciled,
  # it is unmeasured, and saying so is the difference between the two.
  defp reconciled?(attributed, spend) when is_integer(attributed) and is_integer(spend) and spend > 0,
    do: abs(attributed - spend) / spend <= @reconciliation_margin

  defp reconciled?(attributed, 0) when is_integer(attributed), do: attributed == 0
  defp reconciled?(_attributed, _spend), do: nil

  defp direction(attributed, spend) when is_integer(attributed) and is_integer(spend) do
    cond do
      reconciled?(attributed, spend) -> :agrees
      attributed < spend -> :shortfall
      true -> :excess
    end
  end

  defp direction(_attributed, _spend), do: nil

  # What the ranking above is worth — stated per budget, never combined.
  #
  # Core bills requests and GraphQL bills points, on separate windows that reset
  # at different times. Adding the two and printing the sum would invent a
  # quantity ("4% of 10000 spent this window") that describes neither budget and
  # no single window: the same confident-wrong-number failure #1805 reported,
  # committed by the sentence that claims to quantify honesty. So there is no
  # combined figure to render by accident. Each budget carries `attributed`
  # (every call Aiur saw), `named` (only the calls it could tie to a ticket —
  # the ones the ranking can order) and `spend` (what GitHub says that window
  # actually cost).
  @spec coverage([map()], map(), DateTime.t()) :: map()
  def coverage(observations, windows, now) do
    %{resources: coverage_by_resource(observations, windows, now), estimated?: Attribution.estimated?(observations)}
  end

  defp coverage_by_resource(observations, windows, now) do
    windows
    |> Enum.flat_map(fn {resource, window} ->
      case window_spend(window, now) do
        nil ->
          []

        spend ->
          entries = Enum.filter(observations, &(Attribution.observation_resource(&1) == resource))
          named = Enum.reject(entries, &(&1.consumer == @unattributed))

          [
            {resource,
             %{
               attributed: Attribution.total_cost(entries),
               named: Attribution.total_cost(named),
               spend: spend,
               fraction: fraction(Attribution.total_cost(entries), spend),
               named_fraction: fraction(Attribution.total_cost(named), spend),
               estimated?: Attribution.estimated?(entries)
             }}
          ]
      end
    end)
    |> Map.new()
  end

  # A window whose reset has already passed is not the live window. Its
  # `limit - remaining` describes a span that has closed, while attribution has
  # already fallen back to the rolling hour (`window_start/3`) — so reporting
  # one against the other would state a coverage figure "this window" for a
  # window that no longer exists, over calls it never contained. The resource
  # reports no coverage at all until GitHub is observed again.
  defp window_spend(%{limit: limit, remaining: remaining, reset_at: %DateTime{} = reset_at}, now) do
    if DateTime.compare(now, reset_at) == :lt, do: max(limit - remaining, 0), else: nil
  end

  defp window_spend(_window, _now), do: nil

  # A window can report more spend than Aiur attributed, never less that means
  # anything: clamping keeps a stale or double-counted observation from
  # claiming above-total coverage.
  defp fraction(_attributed, spend) when not is_integer(spend) or spend <= 0, do: nil
  defp fraction(attributed, spend), do: Float.round(min(attributed / spend, 1.0), 4)
end
