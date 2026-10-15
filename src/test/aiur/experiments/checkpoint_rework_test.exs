defmodule Aiur.Experiments.CheckpointReworkTest do
  use ExUnit.Case, async: false
  alias Aiur.Experiments.{Checkpoint, Journal, Paths, Persistence, Snapshot, Spec}

  defmodule FileOps do
    def write(fd, bytes) do
      send(self(), {:batch_write, IO.iodata_to_binary(bytes)})
      :file.write(fd, bytes)
    end

    def sync(fd) do
      send(self(), :batch_sync)
      :file.sync(fd)
    end
  end

  defmodule FailedSync do
    def write(fd, bytes), do: :file.write(fd, bytes)
    def sync(_fd), do: {:error, :eio}
  end

  setup do
    root = Path.join(System.tmp_dir!(), "checkpoint-rework-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:aiur, :experiments_dir)
    Application.put_env(:aiur, :experiments_dir, root)
    File.mkdir_p!(root)
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)
    unless Process.whereis(Aiur.PubSub), do: start_supervised!({Phoenix.PubSub, name: Aiur.PubSub})

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :experiments_dir, previous), else: Application.delete_env(:aiur, :experiments_dir)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    {:ok, spec} =
      Spec.new(%{
        id: "checkpoint-rework",
        title: "Checkpoint fixture",
        status: "active",
        design: %{kind: "before_after", change: %{type: "manual", ref: "fixture", time: "2026-10-01T12:00:00Z"}},
        metrics: [%{ref: "fixture/duration"}],
        windows: %{before: %{start: "2026-10-01T00:00:00Z", end: "2026-10-01T12:00:00Z"}, after: %{start: "2026-10-01T12:00:00Z", end: "2026-10-02T12:00:00Z"}}
      })

    File.mkdir_p!(Paths.experiment(spec.id))
    :ok = Persistence.write_json(Paths.file(spec.id, "spec.json"), Spec.to_map(spec))
    %{id: spec.id, root: root}
  end

  defp context(units, limit \\ 2) do
    %{
      catalog: %{packs: %{}, metrics: %{}},
      max_snapshot_observations: limit,
      checkpoint_evaluate: fn spec, name, _ctx ->
        rows = for unit <- units, do: %{"unit_id" => unit, "value" => 1, "at" => "2026-10-01T12:10:00Z", "finished_at" => "2026-10-01T12:11:00Z", "censored" => false}
        {:ok, %{window: spec["windows"][name], metrics: %{"fixture/duration" => %{"observations" => rows}}}}
      end
    }
  end

  test "an oversized checkpoint refuses all observations and journals its limit only once", %{id: id} do
    ctx = context(["one", "two", "three"])
    assert {:ok, %{appended: 0, limit_reached: true}} = Checkpoint.safe_run(id, ~U[2026-10-01 13:00:00Z], ctx)
    refute File.exists?(Paths.file(id, "snapshots/after.partial.ndjson"))
    refute File.exists?(Paths.file(id, "snapshots/after.checkpoint.json"))
    ctx = %{ctx | checkpoint_evaluate: fn _, _, _ -> flunk("limit-reached windows must stop evaluating") end}
    assert {:ok, %{appended: 0, limit_reached: true}} = Checkpoint.safe_run(id, ~U[2026-10-01 15:00:00Z], ctx)
    assert {:ok, [%{"kind" => "checkpoint_limit_reached", "window" => "after", "limit" => 2}]} = Journal.read(Paths.file(id, "journal.ndjson"))
  end

  test "censored observations above the cap stop closure without repeated snapshot failures", %{id: id} do
    ctx = context(["one", "two", "three"])
    evaluate = ctx.checkpoint_evaluate

    ctx = %{
      ctx
      | checkpoint_evaluate: fn spec, name, context ->
          {:ok, data} = evaluate.(spec, name, context)

          metrics =
            Map.new(data.metrics, fn {ref, metric} ->
              rows = Enum.map(metric["observations"], &Map.merge(&1, %{"censored" => true, "finished_at" => nil}))
              {ref, Map.put(metric, "observations", rows)}
            end)

          {:ok, %{data | metrics: metrics}}
        end
    }

    assert {:ok, %{appended: 0, limit_reached: true}} = Checkpoint.safe_run(id, ~U[2026-10-02 12:00:00Z], ctx)
    assert {:ok, [%{"kind" => "checkpoint_limit_reached"}]} = Journal.read(Paths.file(id, "journal.ndjson"))
    refute File.exists?(Paths.file(id, "snapshots/after.r1.json"))
  end

  test "existing partial observations consume the cap without counting duplicate units", %{id: id} do
    assert {:ok, %{appended: 2}} = Checkpoint.run(id, ~U[2026-10-01 13:00:00Z], context(["one", "two"]))
    path = Paths.file(id, "snapshots/after.partial.ndjson")
    bytes = File.read!(path)
    assert {:ok, %{appended: 0}} = Checkpoint.run(id, ~U[2026-10-01 14:00:00Z], context(["one", "two"]))
    assert {:ok, %{appended: 0, limit_reached: true}} = Checkpoint.run(id, ~U[2026-10-01 15:00:00Z], context(["three"]))
    assert File.read!(path) == bytes
  end

  test "preparation writes nothing and closure commits already evaluated data", %{id: id} do
    ctx = context(["final"])
    owner = self()
    evaluate = ctx.checkpoint_evaluate

    ctx = %{
      ctx
      | checkpoint_evaluate: fn spec, name, context ->
          send(owner, :evaluated)
          evaluate.(spec, name, context)
        end
    }

    assert {:ok, plan} = Checkpoint.prepare(id, ~U[2026-10-02 12:00:00Z], ctx)
    assert_received :evaluated
    refute_received :evaluated
    refute File.exists?(Paths.file(id, "snapshots"))
    assert {:ok, %{appended: 1}} = Checkpoint.commit(plan)
    refute_received :evaluated
    assert {:ok, frozen} = Snapshot.latest(id, "after")
    assert [%{"unit_id" => "final", "value" => 1}] = frozen["metrics"]["fixture/duration"]["observations"]
  end

  test "an amendment during evaluation rejects prepared checkpoints before writing", %{id: id} do
    assert {:ok, plan} = Checkpoint.prepare(id, ~U[2026-10-01 13:00:00Z], context(["one"]))
    path = Paths.file(id, "spec.json")
    spec = path |> File.read!() |> Jason.decode!() |> Map.put("title", "Amended during evaluation")
    :ok = Persistence.write_json(path, spec)
    assert {:error, :stale_preparation} = Checkpoint.commit(plan)
    refute File.exists?(Paths.file(id, "snapshots"))
  end

  test "batch append issues one ordered write and one fsync, reporting ambiguous sync failures", %{root: root} do
    path = Path.join(root, "batch.ndjson")
    rows = [%{"n" => 1}, %{"n" => 2}]
    assert :accepted = Aiur.Journal.append_many(path, rows, file_ops: FileOps)
    assert_received {:batch_write, "{\"n\":1}\n{\"n\":2}\n"}
    assert_received :batch_sync
    refute_received {:batch_write, _}
    refute_received :batch_sync
    assert {:ok, ^rows, nil} = Aiur.Journal.replay(path, &{:ok, &1})
    assert {:ambiguous, :eio} = Aiur.Journal.append_many(path, [%{"n" => 3}], file_ops: FailedSync)
  end

  test "experiment batch append refuses a future schema without adding any bytes", %{root: root} do
    path = Path.join(root, "future.ndjson")
    bytes = Jason.encode!(%{"schema_version" => 2}) <> "\n"
    File.write!(path, bytes)
    assert {:error, {:newer_version, 2}} = Journal.append_many(path, [%{"schema_version" => 1}])
    assert File.read!(path) == bytes
  end
end
