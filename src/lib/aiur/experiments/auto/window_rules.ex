defmodule Aiur.Experiments.Auto.WindowRules do
  @moduledoc false
  @day 86_400

  @spec collecting?(map()) :: boolean()
  def collecting?(spec), do: spec["status"] == "active" and get_in(spec, ["design", "kind"]) == "before_after"

  @spec evaluate(map(), term(), map(), DateTime.t()) :: :noop | {:extend, String.t()} | {:report_due, String.t(), String.t()}
  def evaluate(spec, samples, config, now) do
    if collecting?(spec), do: decide(spec, samples, config, now), else: :noop
  end

  defp decide(spec, samples, config, now) do
    start = timestamp(get_in(spec, ["windows", "after", "start"]))
    minimum = DateTime.add(start, config.after_days * @day)
    maximum = DateTime.add(start, config.after_max_days * @day)
    stop = earlier(timestamp(get_in(spec, ["windows", "after", "end"])) || minimum, maximum)
    guard_met? = met?(samples)

    cond do
      guard_met? and not reached?(now, minimum) -> :noop
      guard_met? -> {:report_due, "guard_met", iso(earlier(now, stop))}
      not reached?(now, stop) -> :noop
      reached?(now, maximum) -> {:report_due, "insufficient_data", iso(maximum)}
      true -> {:extend, iso(earlier(DateTime.add(stop, config.after_step_days * @day), maximum))}
    end
  end

  @spec truncate(map(), term(), DateTime.t()) :: :noop | {:report_due, String.t(), String.t()}
  def truncate(spec, samples, at) do
    start = timestamp(get_in(spec, ["windows", "after", "start"]))
    stop = timestamp(get_in(spec, ["windows", "after", "end"])) || at

    if collecting?(spec) and DateTime.compare(at, start) == :gt do
      {:report_due, if(met?(samples), do: "guard_met", else: "truncated"), iso(earlier(at, stop))}
    else
      :noop
    end
  end

  @spec met?(term()) :: boolean()
  def met?(true), do: true
  def met?(%{guard_met?: true}), do: true
  def met?(%{"guard_met?" => true}), do: true
  def met?({:ok, samples}), do: met?(samples)
  def met?(samples) when is_map(samples), do: map_size(samples) > 0 and Enum.all?(Map.values(samples), &met?/1)
  def met?(samples) when is_list(samples), do: samples != [] and Enum.all?(samples, &met?/1)
  def met?(_unavailable), do: false

  defp timestamp(nil), do: nil
  defp timestamp(value), do: value |> DateTime.from_iso8601() |> elem(1)
  defp reached?(now, at), do: DateTime.compare(now, at) != :lt
  defp earlier(left, right), do: if(DateTime.compare(left, right) == :lt, do: left, else: right)
  defp iso(at), do: DateTime.to_iso8601(at)
end
