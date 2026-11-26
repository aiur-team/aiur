defmodule Aiur.Experiments.Auto.WindowTransition do
  @moduledoc false
  alias Aiur.Experiments.Auto.WindowRules
  alias Aiur.Experiments.Reader

  @spec prepare(String.t(), term(), map(), DateTime.t(), term()) :: {:ok, map(), term()} | :noop | {:error, term()}
  def prepare(id, samples, config, now, truncation) do
    case Reader.spec(id) do
      {:ok, spec, false} ->
        action = if truncation, do: WindowRules.truncate(spec, samples, now), else: WindowRules.evaluate(spec, samples, config, now)
        changes(action, spec, truncation)

      {:ok, _spec, true} ->
        {:error, :store_read_only}

      error ->
        error
    end
  end

  defp changes(:noop, _spec, _truncation), do: :noop

  defp changes({:extend, stop}, spec, _truncation) do
    {:ok, %{"windows" => put_in(spec["windows"], ["after", "end"], stop)}, {"window_extended", nil}}
  end

  defp changes({:report_due, reason, stop}, spec, truncation) do
    changes = %{"status" => "report_due", "report_reason" => reason, "windows" => put_in(spec["windows"], ["after", "end"], stop)}
    {:ok, changes, {"report_due", truncation || reason}}
  end
end
