defmodule AiurWeb.OperatorControlCenter.Analytics.RetainedMemoryTest do
  use ExUnit.Case, async: false
  alias Aiur.RunTelemetry.Summaries
  alias AiurWeb.OperatorControlCenter.Analytics.Presenter

  @fixture Path.expand("../../../fixtures/analytics/runs/boot-a/run-summary.json", __DIR__)
  @bound 150 * 1024 * 1024

  setup do
    root = Path.join(System.tmp_dir!(), "retained-memory-#{System.unique_integer([:positive])}")
    old = for key <- [:repo_base_root, :analytics_repo], do: {key, Application.fetch_env(:aiur, key)}
    Application.put_env(:aiur, :repo_base_root, root)
    Application.put_env(:aiur, :analytics_repo, "memory/test")

    on_exit(fn ->
      Enum.each(old, fn
        {key, {:ok, value}} -> Application.put_env(:aiur, key, value)
        {key, :error} -> Application.delete_env(:aiur, key)
      end)

      File.rm_rf!(root)
    end)

    %{root: root}
  end

  @tag timeout: 120_000
  test "presenter peak VM growth stays below 150 MiB for one and three cold requests on 210 MB summaries", %{root: root} do
    for {session, callers} <- [{:current, 1}, {:current, 3}, {:cross, 3}] do
      Application.put_env(:aiur, :analytics_repo, "memory/test-#{session}-#{callers}")
      path = Summaries.run_summary_path("retained")
      write_large(path)
      assert File.stat!(path).size > 200 * 1024 * 1024
      :erlang.garbage_collect()
      baseline = :erlang.memory(:total)
      tasks = for _ <- 1..callers, do: Task.async(fn -> Presenter.load(session: session, telemetry_file: Path.join(root, "missing.ndjson")) end)
      {peak, results} = observe(tasks, baseline, [])
      assert peak - baseline < @bound, "peak VM growth #{peak - baseline} bytes exceeds #{@bound}"
      assert Enum.all?(results, &match?({:ok, %{available?: true}}, &1))
    end
  end

  defp write_large(path) do
    summary = @fixture |> File.read!() |> Jason.decode!()
    {records, rest} = Map.pop(summary, "records")
    encoded = Jason.encode!(rest)
    suffix = binary_part(encoded, 1, byte_size(encoded) - 1)
    warning = records |> hd() |> Map.put("kind", "warning") |> Map.put("details", String.duplicate("x", 55_000)) |> Jason.encode!()
    File.mkdir_p!(Path.dirname(path))

    File.open!(path, [:write, :binary], fn file ->
      IO.binwrite(file, "{\"records\":[")
      for _ <- 1..4000, do: IO.binwrite(file, [warning, ","])
      IO.binwrite(file, [Enum.map_join(records, ",", &Jason.encode!/1), "],", suffix])
    end)
  end

  defp observe([], peak, results), do: {peak, results}

  defp observe(tasks, peak, results) do
    peak = max(peak, :erlang.memory(:total))
    yielded = Task.yield_many(tasks, timeout: 5)
    pending = for {task, nil} <- yielded, do: task
    completed = for {_task, {:ok, result}} <- yielded, do: result
    assert Enum.all?(yielded, fn {_task, result} -> is_nil(result) or match?({:ok, _}, result) end)
    observe(pending, peak, completed ++ results)
  end
end
