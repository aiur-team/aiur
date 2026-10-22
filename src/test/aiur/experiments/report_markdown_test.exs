defmodule Aiur.Experiments.ReportMarkdownTest do
  use ExUnit.Case, async: true
  alias Aiur.Experiments.ReportMarkdown
  @fixtures Path.expand("../../fixtures/experiments", __DIR__)

  test "golden report renders every section to the golden Markdown" do
    report = @fixtures |> Path.join("report.valid.json") |> File.read!() |> Jason.decode!()
    assert ReportMarkdown.render(report) == File.read!(Path.join(@fixtures, "report.valid.md"))
  end

  test "unavailable values stay explicit, confounders and sensitivity are visible" do
    report = @fixtures |> Path.join("report.valid.json") |> File.read!() |> Jason.decode!()
    report = report |> put_in(["preregistration", "record", "post_hoc"], true) |> put_in(["results", Access.at(0), "ci95"], nil)
    report = Map.put(report, "sensitivity", [%{"id" => "s1", "what" => "Exclude cap window", "conclusion_holds" => false, "results" => report["results"]}])
    output = ReportMarkdown.render(report)
    assert output =~ "(POST-HOC)"
    assert output =~ "95% CI unavailable"
    assert output =~ "s1: Exclude cap window; conclusion holds: false"
    assert output =~ "cap-1: Cap changed"
    assert output =~ "SRM p=unavailable"
  end
end
