defmodule Aiur.Experiments.ReportMarkdown do
  @moduledoc "Renders report.v1 with numbered label evidence and all reproducibility fields."

  @spec render(map()) :: String.t()
  def render(report) do
    header = report["header"]
    analyst = header["analyst"]

    sections = [
      section("Summary", report["summary"]),
      section("Pre-registration", registration(report["preregistration"])),
      section("Design and sample", sample(report)),
      section("Results", results(report["results"])),
      section("Confounders reviewed", confounders(report["confounders"])),
      section("Sensitivity analyses", sensitivity(report["sensitivity"])),
      section("Threats to validity", fields(report["threats"])),
      section("Recommendation", recommendation(report["recommendation"])),
      section("Reproduce", fields(report["reproduce"]) <> "\n\n" <> fields(header))
    ]

    "# #{header["title"]} - #{header["analysis_type"]} report v#{header["report_version"]}\n\n" <>
      "#{header["generated_at"]} · analyst #{analyst["agent"]}/#{analyst["model"]} · stats #{String.slice(header["stats_snapshot_hash"], 0, 8)} · events #{String.slice(header["events_snapshot_hash"], 0, 8)}\n" <>
      "Labels: #{chips(report["results"])}\n\n" <> Enum.join(sections, "\n\n") <> "\n"
  end

  defp chips(rows) do
    rows
    |> Enum.filter(&(&1["role"] == "primary"))
    |> Enum.map_join("; ", fn row ->
      "#{label(row)} (n=#{values(row["n"])}, effect #{format(row["effect"]["value"])}, 95% CI #{format(row["ci95"])})"
    end)
  end

  defp registration(%{"record" => record, "deviations" => deviations}) do
    timing = if record["post_hoc"], do: "POST-HOC", else: "on time"
    "Registered #{record["registered_at"]} (#{timing})\n\n" <> fields(record) <> "\n\nDeviations: " <> format(deviations)
  end

  defp sample(report) do
    sample = report["sample"]

    fields(report["design"]) <>
      "\n\n" <>
      table(~w(cohort stratum n excluded), Enum.map(sample["cohorts"], fn row -> Enum.map(~w(cohort stratum n excluded), &row[&1]) end)) <>
      "\n\nBalance: #{format(sample["balance"])}; SRM p=#{format(sample["srm_p"])}"
  end

  defp results(rows) do
    headings = ["metric", "role", "n A / B", "median A / B (IQR)", "effect [95% CI]", "p (adj.)", "power @ MDE", "MDE at n", "n needed", "label"]

    table(headings, Enum.map(rows, &result_cells/1)) <>
      "\n\n" <>
      Enum.map_join(rows, "\n", fn row -> "#{row["metric"]}: " <> fields(Map.take(row, ~w(unit family engine_label label_reason direction))) end)
  end

  defp result_cells(row) do
    [
      row["metric"],
      row["role"],
      values(row["n"]),
      "#{values(row["median"])} (#{values(row["iqr"])})",
      "#{row["effect"]["kind"]} #{format(row["effect"]["value"])} [#{format(row["ci95"])}]",
      "#{format(row["p"])} (#{format(row["p_adjusted"])})",
      row["power_at_mde"],
      row["mde_at_n"],
      row["n_needed_per_cohort"],
      label(row)
    ]
  end

  defp confounders([]), do: "No collected events."

  defp confounders(rows) do
    table(
      ["when", "kind", "event", "affects", "bias", "severity", "handling"],
      Enum.map(rows, fn row ->
        [
          row["at"],
          row["kind"],
          "#{row["event_id"]}: #{row["title"]} (#{row["ref"]}; #{row["classification"]})",
          row["affects"],
          row["bias"],
          row["severity"],
          "#{row["handling"]}: #{row["note"]} #{row["sensitivity_id"]}"
        ]
      end)
    )
  end

  defp sensitivity([]), do: "No sensitivity analyses."
  defp sensitivity(rows), do: Enum.map_join(rows, "\n\n", fn row -> "#{row["id"]}: #{row["what"]}; conclusion holds: #{row["conclusion_holds"]}\n\n" <> results(row["results"]) end)
  defp recommendation(row), do: "#{row["action"]} - #{row["why"]}. Changes if #{row["condition"]}. Next analysis: #{format(row["next_analysis"])}."
  defp label(row), do: Enum.join([row["label"] | row["modifiers"]], ", ")
  defp section(title, text), do: "## #{title}\n#{text}"
  defp fields(map), do: map |> Enum.sort() |> Enum.map_join("\n", fn {key, value} -> "#{key}: #{format(value)}" end)
  defp values(map), do: map |> Enum.sort() |> Enum.map_join(" / ", fn {key, value} -> "#{key}=#{format(value)}" end)
  defp format(nil), do: "unavailable"
  defp format(value) when is_binary(value), do: value
  defp format(value), do: Jason.encode!(value)
  defp cell(value), do: value |> format() |> String.replace("|", "\\|") |> String.replace("\n", "<br>")
  defp table(headings, rows), do: Enum.map_join([headings, Enum.map(headings, fn _heading -> "---" end) | rows], "\n", fn row -> "| " <> Enum.map_join(row, " | ", &cell/1) <> " |" end)
end
