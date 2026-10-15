defmodule Aiur.Experiments.Auto.ConcurrentChanges do
  @moduledoc false
  require Logger
  alias Aiur.Experiments
  alias Aiur.Experiments.Auto.{Line, SpecBuilder}

  @spec annotate(String.t(), Line.t()) :: :ok | {:error, term()}
  def annotate(id, line) do
    with {:ok, experiments} <- Experiments.list([]) do
      experiments
      |> Enum.filter(&(&1.id != id and Map.get(&1, :status) in ["active", "draft"]))
      |> Enum.sort_by(& &1.id)
      |> Enum.reduce_while(:ok, fn row, :ok ->
        continue(annotate_one(row.id, line))
      end)
    end
  end

  defp continue(:ok), do: {:cont, :ok}
  defp continue(error), do: {:halt, error}

  defp annotate_one(id, line) do
    with {:ok, experiment} <- Experiments.fetch(id) do
      annotate_experiment(id, experiment, line)
    end
  end

  defp annotate_experiment(id, %{read_only?: true}, _line) do
    if is_nil(Process.put({__MODULE__, :read_only, id}, true)) do
      Logger.warning("automatic experiment concurrent annotation skipped: read-only experiment id=#{id}")
    end

    :ok
  end

  defp annotate_experiment(id, %{read_only?: false} = experiment, line) do
    seen? = Enum.any?(experiment.annotations, &(&1["auto_line_key"] == line.key))
    inside? = Enum.any?(experiment.spec["windows"], fn {_name, window} -> contains?(window, line.at) end)

    if inside? and not seen? do
      Experiments.annotate(id, %{kind: "confounder", at: DateTime.to_iso8601(line.at), auto_line_key: line.key, reason: "concurrent change: #{line.source} #{SpecBuilder.ref(line)}"}, "auto")
    else
      :ok
    end
  end

  defp contains?(%{"start" => from, "end" => until}, at) do
    {:ok, from, _offset} = DateTime.from_iso8601(from)
    after_start? = DateTime.compare(at, from) != :lt
    after_start? and (is_nil(until) or before_end?(at, until))
  end

  defp before_end?(at, until) do
    {:ok, until, _offset} = DateTime.from_iso8601(until)
    DateTime.compare(at, until) == :lt
  end
end
