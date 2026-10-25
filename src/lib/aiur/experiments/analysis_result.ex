defmodule Aiur.Experiments.AnalysisResult do
  @moduledoc false
  alias Aiur.Experiments.{Paths, Reader}

  @spec read(String.t(), map()) :: {:ok, map() | nil} | {:error, :unreadable}
  def read(id, spec) do
    case Reader.json(Paths.file(id, "result.json")) do
      {:error, :not_found} ->
        {:ok, nil}

      {:ok, %{"body" => %{"schema_version" => "experiment-result/v1", "experiment_id" => ^id, "metrics" => metrics, "group_order" => [a, b]} = body}}
      when is_map(metrics) and is_binary(a) and is_binary(b) and a != b ->
        with :ok <- validate(body, spec), do: {:ok, body}

      _invalid ->
        {:error, :unreadable}
    end
  end

  @spec validate(term(), map()) :: :ok | {:error, :unreadable}
  def validate(%{"schema_version" => "experiment-result/v1", "experiment_id" => id, "metrics" => metrics, "group_order" => [a, b]} = body, spec)
      when is_map(metrics) and is_binary(a) and is_binary(b) and a != b do
    if id == spec["id"] and valid?(body, spec), do: :ok, else: {:error, :unreadable}
  end

  def validate(_body, _spec), do: {:error, :unreadable}

  defp valid?(body, spec) do
    minimum = get_in(body, ["defaults", "min_samples"])
    is_integer(minimum) and minimum > 0 and minimum == spec["min_samples"] and Enum.all?(body["metrics"], fn {_ref, metric} -> valid_metric?(metric, body["group_order"], minimum) end)
  rescue
    _invalid -> false
  end

  defp valid_metric?(metric, order, minimum) when is_map(metric) do
    classification?(metric) and samples?(metric, order, minimum) and
      Enum.all?(metric["analyst_flags"], &(is_map(&1) and is_binary(&1["flag"]) and is_binary(&1["reason"]))) and
      numbers?(metric, ~w(p_raw p_adj)) and effects?(Map.get(metric, "effects", %{})) and is_map(Map.get(metric, "tests", %{}))
  end

  defp valid_metric?(_metric, _order, _minimum), do: false

  defp classification?(metric) do
    metric["status"] in ~w(insufficient_data inconclusive significant practically_equivalent) and
      metric["direction"] in ~w(improved regressed no_change) and metric["adjustment"] in ~w(holm bh) and
      (is_nil(metric["primary_effect"]) or is_binary(metric["primary_effect"]))
  end

  defp samples?(metric, order, minimum) do
    Enum.all?(order, fn name ->
      group = get_in(metric, ["groups", name])
      valid_group?(group) and (metric["status"] == "insufficient_data" or group["n"] >= minimum)
    end)
  end

  defp effects?(effects) when is_map(effects), do: Enum.all?(effects, fn {_name, effect} -> is_map(effect) and numbers?(effect, ~w(estimate lo hi)) end)
  defp effects?(_effects), do: false

  defp valid_group?(values) when is_map(values), do: is_integer(values["n"]) and values["n"] >= 0 and numbers?(values, ~w(median q1 q3 rate exposure events))
  defp valid_group?(_values), do: false
  defp numbers?(values, keys), do: Enum.all?(keys, &(is_nil(values[&1]) or is_number(values[&1])))
end
