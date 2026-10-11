defmodule Aiur.Experiments.Sources.Ndjson do
  @moduledoc false

  alias Aiur.Experiments.{Coverage, Observation, Paths}
  alias Aiur.Experiments.Sources.Common

  @spec observations(term(), String.t(), map(), map()) :: map()
  def observations(metric, _ref, window, ctx) do
    with {:ok, path} <- resolve_path(metric.source["path"], ctx),
         {:ok, body} <- File.read(path) do
      parse(body, metric, window, ctx)
    else
      {:error, reason} -> Common.unavailable(reason)
    end
  end

  @spec parse(String.t(), term(), map(), map()) :: map()
  def parse(body, metric, window, ctx) do
    {observations, malformed} =
      body
      |> String.split("\n", trim: true)
      |> Enum.reduce({[], 0}, fn line, {rows, bad} ->
        with {:ok, data} <- Jason.decode(line),
             {:ok, observation} <- Observation.new(data) do
          {[observation | rows], bad}
        else
          _invalid -> {rows, bad + 1}
        end
      end)

    observations = Enum.reverse(observations)
    facts = Map.get(ctx, :data_facts, Enum.flat_map(observations, &Common.facts(&1.attrs)))
    earliest = observations |> Enum.map(& &1.at) |> Enum.min(DateTime, fn -> nil end)
    coverage = Coverage.classify(metric.requires, facts, window, earliest)
    coverage = if malformed > 0, do: Map.put(coverage, :malformed_lines, malformed), else: coverage
    Common.result(coverage, Enum.filter(observations, &Common.in_window?(&1.at, window)))
  end

  defp resolve_path("state:" <> relative, ctx) do
    root = Map.get_lazy(ctx, :state_path, fn -> Paths.root() |> Path.dirname() end)
    contained(root, relative)
  end

  defp resolve_path(relative, ctx), do: contained(Common.repo_path(ctx), relative)

  defp contained(root, relative) do
    case Aiur.PathSafety.contained?(root, Path.expand(relative, root)) do
      {:ok, %{candidate: path}} -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end
end
