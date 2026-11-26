defmodule Aiur.Experiments.AnalysisReadTest do
  use ExUnit.Case, async: false
  alias Aiur.Experiments
  @metric "delivery-speed/start_to_merge"

  setup do
    root = Path.join(System.tmp_dir!(), "experiment-analysis-read-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:aiur, :experiments_dir)
    Application.put_env(:aiur, :experiments_dir, root)
    spec = fixture("valid_line")["spec"] |> Map.put("min_samples", 10)
    directory = Path.join(root, spec["id"])
    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "spec.json"), Jason.encode!(spec))

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :experiments_dir, previous), else: Application.delete_env(:aiur, :experiments_dir)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    %{directory: directory, id: spec["id"]}
  end

  test "facade exposes engine output and preserves missing-result state", %{directory: directory, id: id} do
    assert {:ok, %{analysis: nil}} = Experiments.fetch(id)
    body = body(id)
    write(directory, %{"body" => body})
    assert {:ok, %{analysis: ^body}} = Experiments.fetch(id)
  end

  test "malformed, foreign and unsupported result envelopes fail closed", %{directory: directory, id: id} do
    for value <- [%{}, %{"body" => body("other-id")}, %{"body" => Map.put(body(id), "schema_version", "future")}, %{"body" => put_in(body(id), ["defaults", "min_samples"], 15)}] do
      write(directory, value)
      assert {:error, :unreadable} = Experiments.fetch(id)
    end

    File.write!(Path.join(directory, "result.json"), "bad JSON")
    assert {:error, :unreadable} = Experiments.fetch(id)
  end

  test "nested malformed metric values are rejected through the real facade", %{directory: directory, id: id} do
    metric = body(id)["metrics"][@metric]

    invalid = [
      nil,
      [],
      Map.put(metric, "status", "inconclusive"),
      Map.put(metric, "groups", []),
      put_in(metric, ["groups", "after", "n"], -1),
      put_in(metric, ["groups", "after", "median"], "unknown"),
      Map.put(metric, "effects", []),
      Map.put(metric, "effects", %{"median_ratio" => %{"estimate" => "bad"}}),
      Map.put(metric, "analyst_flags", nil),
      Map.put(metric, "analyst_flags", [%{"flag" => "confounded"}]),
      Map.put(metric, "tests", []),
      Map.put(metric, "p_raw", "small")
    ]

    for value <- invalid do
      write(directory, %{"body" => put_in(body(id), ["metrics", @metric], value)})
      assert {:error, :unreadable} = Experiments.fetch(id)
    end
  end

  defp body(id), do: fixture("results/page_analysis")["body"] |> Map.put("experiment_id", id)
  defp fixture(name), do: Path.expand("fixtures/#{name}.json", __DIR__) |> File.read!() |> Jason.decode!()
  defp write(directory, value), do: File.write!(Path.join(directory, "result.json"), Jason.encode!(value))
end
