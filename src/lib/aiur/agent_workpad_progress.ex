defmodule Aiur.AgentWorkpadProgress do
  @moduledoc """
  Parses only the safe checklist facts needed for ticket progress.
  """

  @phases ~w(plan work review pr ci merge)
  @bands %{"plan" => {0, 15}, "work" => {15, 70}, "review" => {70, 80}, "pr" => {80, 85}, "ci" => {85, 95}, "merge" => {95, 100}}

  @spec parse(term()) :: map() | nil
  def parse(body) when is_binary(body) do
    if String.starts_with?(String.trim_leading(body), "## Agent Workpad") do
      rows = Regex.scan(~r/^\s*[-*]\s+\[([ xX])\]\s+(.+)$/mu, body, capture: :all_but_first)
      phase = phase(body)
      total = length(rows)
      done = Enum.count(rows, fn [mark, _step] -> String.downcase(mark) == "x" end)

      progress(rows, phase, done, total)
    end
  end

  def parse(_body), do: nil

  defp progress(_rows, _phase, _done, 0), do: nil

  defp progress(rows, phase, done, total) do
    step = rows |> Enum.find(fn [mark, _] -> String.downcase(mark) != "x" end) |> row_step(phase)
    {start, finish} = Map.fetch!(@bands, phase)
    percent = start + div((finish - start) * done, total)

    %{percent: percent, step: step, phase: phase, source: "checklist", done: done, total: total}
  end

  defp phase(body) do
    case Regex.run(~r/^\s*[-*]\s*Phase:\s*(plan|work|review|pr|ci|merge)\s*$/im, body, capture: :all_but_first) do
      [phase] when phase in @phases -> phase
      _ -> "work"
    end
  end

  defp row_step(nil, phase), do: "#{String.capitalize(phase)} work in progress"
  defp row_step([_mark, step], _phase), do: step |> String.replace(~r/[\r\n\t]+/u, " ") |> String.trim() |> String.slice(0, 120)
end
