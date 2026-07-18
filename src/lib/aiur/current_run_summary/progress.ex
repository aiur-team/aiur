defmodule Aiur.CurrentRunSummary.Progress do
  @moduledoc false

  @spec build([map()], map(), map(), map()) :: %{progress: map(), eta: map()}
  def build(members, weights, run, context) do
    %{
      progress: progress(members, weights, run, context),
      eta: eta(weights, run, context)
    }
  end

  defp progress(members, weights, run, context) do
    weighted_numerator =
      Enum.reduce(members, 0, fn
        %{progress: {:known, percent}, weight: weight}, total -> total + weight * percent
        _member, total -> total
      end)

    denominator = weights.eligible * 100

    exact? =
      run.valid? and weights.eligible > 0 and weights.unknown_progress == 0 and
        context.weight_health == :healthy and not context.truncated? and
        context.source_health.membership == :healthy and context.membership_freshness == :fresh

    %{
      scale: 100,
      weighted_numerator: %{value: weighted_numerator, scale: 100},
      denominator_weight: weights.eligible,
      known_weight: weights.known_progress,
      unknown_weight: weights.unknown_progress,
      lower_bound: fraction(weighted_numerator, denominator),
      coverage: fraction(weights.known_progress, weights.eligible),
      exact: if(exact?, do: fraction(weighted_numerator, denominator))
    }
  end

  defp eta(weights, run, context) do
    base = %{
      formula_version: "completed_weight_rate_v1",
      sample_count: context.counts.successful_terminal,
      completed_weight: weights.successful_terminal,
      remaining_weight: weights.remaining,
      denominator_generation: context.denominator_generation,
      observed_at: run.observed_at
    }

    case eta_unavailable_reason(weights, run, context) do
      nil -> available_eta(base, weights, run)
      reason -> unavailable_eta(base, reason)
    end
  end

  defp eta_unavailable_reason(weights, run, context) do
    source_unavailable_reason(run, context) || evidence_unavailable_reason(weights, run, context)
  end

  defp source_unavailable_reason(run, context) do
    cond do
      not run.valid? -> :invalid_run_window
      context.source_health.membership != :healthy -> :unhealthy_membership
      context.membership_freshness != :fresh -> :membership_not_fresh
      context.truncated? -> :truncated_membership
      context.weight_health != :healthy -> :unhealthy_weight_facts
      true -> nil
    end
  end

  defp evidence_unavailable_reason(weights, run, context) do
    cond do
      weights.eligible == 0 -> :zero_eligible_weight
      context.counts.successful_terminal < 2 -> :insufficient_successful_completions
      run.elapsed_wall_seconds < 600 -> :insufficient_elapsed_time
      weights.successful_terminal <= 0 -> :zero_completed_weight
      true -> nil
    end
  end

  defp available_eta(base, weights, run) do
    Map.merge(base, %{
      status: :available,
      reason: nil,
      confidence: :evidence_based,
      throughput_weight_per_second: fraction(weights.successful_terminal, run.elapsed_wall_seconds),
      duration_seconds: fraction(weights.remaining * run.elapsed_wall_seconds, weights.successful_terminal)
    })
  end

  defp unavailable_eta(base, reason) do
    Map.merge(base, %{
      status: :unavailable,
      reason: reason,
      confidence: :unavailable,
      throughput_weight_per_second: nil,
      duration_seconds: nil
    })
  end

  defp fraction(_numerator, denominator) when not is_integer(denominator) or denominator <= 0,
    do: nil

  defp fraction(numerator, denominator) when is_integer(numerator) do
    divisor = Integer.gcd(abs(numerator), denominator)
    %{numerator: div(numerator, divisor), denominator: div(denominator, divisor)}
  end
end
