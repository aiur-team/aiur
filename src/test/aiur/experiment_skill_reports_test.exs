defmodule Aiur.ExperimentSkillReportsTest do
  use ExUnit.Case, async: true

  alias Aiur.Experiments.{Evidence, ReportContract, ReportMarkdown}

  @repo_root Path.expand("../../..", __DIR__)
  @references Path.join(@repo_root, ".claude/skills/aiur-experiment/references")

  test "analyst template is byte-identical to the renderer's published template" do
    assert File.read!(Path.join(@references, "report-template.md")) ==
             File.read!(Application.app_dir(:aiur, "priv/experiments/report-template.md"))
  end

  for kind <- ~w(feature cohorts) do
    @kind kind
    test "worked #{@kind} report validates unchanged against its separate frozen evidence" do
      report = example("report.#{@kind}.json")
      frozen = example("report.#{@kind}.evidence.json")

      context =
        Map.new(~w(experiment_id stats_snapshot_hash preregistration events engine_labels engine_results)a, fn key ->
          {key, Map.fetch!(frozen, Atom.to_string(key))}
        end)

      assert report["header"]["preregistration_hash"] == Evidence.hash(context.preregistration)
      assert {:ok, ^report, []} = ReportContract.validate(report, context)
      assert ReportMarkdown.render(report) =~ "## Confounders reviewed"
    end
  end

  defp example(file), do: @references |> Path.join("examples/#{file}") |> File.read!() |> Jason.decode!()
end
