defmodule Aiur.Experiments.CheckpointerTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Aiur.Experiments.{Checkpoint, Checkpointer, Journal, Paths, Persistence, Reader, Snapshot, Spec}

  setup do
    root = Path.join(System.tmp_dir!(), "experiment-checkpoint-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:aiur, :experiments_dir)
    Application.put_env(:aiur, :experiments_dir, root)

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :experiments_dir, previous), else: Application.delete_env(:aiur, :experiments_dir)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)
    unless Process.whereis(Aiur.PubSub), do: start_supervised!({Phoenix.PubSub, name: Aiur.PubSub})
    %{id: write_spec("checkpoint-fixture")}
  end

  defp write_spec(id, status \\ "active") do
    {:ok, spec} =
      Spec.new(%{
        id: id,
        title: "Checkpoint fixture",
        hypothesis: "Faster delivery",
        status: status,
        design: %{kind: "before_after", change: %{type: "manual", ref: "fixture", time: "2026-10-01T12:00:00Z"}},
        metrics: [%{ref: "fixture/duration"}],
        windows: %{before: %{start: "2026-10-01T00:00:00Z", end: "2026-10-01T12:00:00Z"}, after: %{start: "2026-10-01T12:00:00Z", end: "2026-10-02T12:00:00Z"}}
      })

    File.mkdir_p!(Paths.experiment(id))
    :ok = Persistence.write_json(Paths.file(id, "spec.json"), Spec.to_map(spec))
    id
  end

  defp context(rows) do
    %{
      checkpoint_latest: fn _id, _name -> {:ok, nil} end,
      checkpoint_evaluate: fn spec, name, _context ->
        {:ok, %{window: spec["windows"][name], metrics: %{"fixture/duration" => %{"observations" => rows}}}}
      end,
      checkpoint_freeze: fn _id, name, opts ->
        send(self(), {:freeze, name, opts})
        {:ok, %{}}
      end
    }
  end

  defp row(unit, finish, extra \\ %{}) do
    Map.merge(%{"unit_id" => unit, "value" => 500, "at" => "2026-10-01T12:05:00Z", "finished_at" => finish, "censored" => is_nil(finish)}, extra)
  end

  test "finished observations append once and open durations wait until finished", %{id: id} do
    now = ~U[2026-10-01 13:00:00Z]
    first = context([row("one", "2026-10-01T12:15:00Z"), row("two", nil)])
    assert {:ok, %{appended: 1}} = Checkpoint.run(id, now, first)
    assert {:ok, %{appended: 0}} = Checkpoint.run(id, now, first)
    assert {:ok, [%{"observation" => %{"unit_id" => "one"}}]} = Checkpoint.partial(id, "after")

    finished = context([row("one", "2026-10-01T12:15:00Z"), row("two", "2026-10-01T13:15:00Z")])
    assert {:ok, %{appended: 1}} = Checkpoint.run(id, DateTime.add(now, 3_600), finished)
    assert {:ok, entries} = Checkpoint.partial(id, "after")
    assert Enum.map(entries, & &1["observation"]["unit_id"]) == ["one", "two"]
    assert {:ok, metadata} = Reader.json(Paths.file(id, "snapshots/after.checkpoint.json"))
    assert metadata["last_checkpoint_at"] == "2026-10-01T14:00:00Z"
  end

  test "at timestamps finalize count rows but explicit nil finishes and censored rows do not", %{id: id} do
    rows = [Map.delete(row("count", nil, %{"censored" => false}), "finished_at"), row("open", nil, %{"censored" => false}), row("censored", "2026-10-01T12:15:00Z", %{"censored" => true})]
    assert {:ok, %{appended: 1}} = Checkpoint.run(id, ~U[2026-10-01 13:00:00Z], context(rows))
    assert {:ok, [%{"observation" => %{"unit_id" => "count"}}]} = Checkpoint.partial(id, "after")
  end

  test "at change time the bounded before snapshot is revised only until it covers the final baseline", %{id: id} do
    {:ok, revisions} = Agent.start_link(fn -> %{"window" => %{"end" => "2026-10-01T11:00:00Z"}} end)
    on_exit(fn -> if Process.alive?(revisions), do: Agent.stop(revisions) end)

    ctx = context([])

    ctx = %{
      ctx
      | checkpoint_latest: fn _id, name -> {:ok, if(name == "before", do: Agent.get(revisions, & &1))} end,
        checkpoint_freeze: fn _id, "before", opts ->
          assert opts[:reason] == "change_time_reached"
          assert opts[:now] == ~U[2026-10-01 12:00:00Z]
          send(self(), :refrozen)
          Agent.update(revisions, fn _ -> %{"window" => %{"end" => "2026-10-01T12:00:00Z"}} end)
          {:ok, %{}}
        end
    }

    assert {:ok, %{appended: 0}} = Checkpoint.run(id, ~U[2026-10-01 11:30:00Z], ctx)
    refute_received :refrozen
    assert {:ok, %{appended: 0}} = Checkpoint.run(id, ~U[2026-10-01 12:00:00Z], ctx)
    assert_received :refrozen
    assert {:ok, %{appended: 0}} = Checkpoint.run(id, ~U[2026-10-01 13:00:00Z], ctx)
    refute_received :refrozen
  end

  test "closing a window freezes after appending final data and retains partial evidence", %{id: id} do
    assert {:ok, %{appended: 1}} = Checkpoint.run(id, ~U[2026-10-02 12:00:00Z], context([row("final", "2026-10-02T11:59:00Z")]))
    assert_received {:freeze, "after", opts}
    assert opts[:now] == ~U[2026-10-02 12:00:00Z]
    assert {:ok, [%{"observation" => %{"unit_id" => "final"}}]} = Checkpoint.partial(id, "after")
    frozen = %{context([]) | checkpoint_latest: fn _id, _name -> {:ok, %{"window" => %{"end" => "2026-10-02T12:00:00Z"}}} end}
    assert {:ok, %{appended: 0}} = Checkpoint.run(id, ~U[2026-10-02 13:00:00Z], frozen)
    refute_received {:freeze, _, _}
  end

  test "real snapshots revise at change time and retain checkpointed units after live data disappears", %{id: id} do
    ctx = %{
      catalog: %{packs: %{}, metrics: %{}},
      evaluate: fn _refs, _window, _ctx ->
        %{"fixture/duration" => %{"coverage" => %{"status" => "complete"}, "observations" => [row("saved", "2026-10-01T12:15:00Z")]}}
      end
    }

    assert {:ok, %{"revision" => 1}} = Snapshot.freeze(id, "before", now: ~U[2026-10-01 11:00:00Z], context: ctx)
    assert {:ok, %{appended: 1}} = Checkpoint.run(id, ~U[2026-10-01 13:00:00Z], ctx)
    assert {:ok, %{"revision" => 2, "window" => %{"end" => "2026-10-01T12:00:00Z"}}} = Snapshot.latest(id, "before")
    assert {:ok, %{appended: 0}} = Checkpoint.run(id, ~U[2026-10-01 14:00:00Z], ctx)
    assert {:ok, %{"revision" => 2}} = Snapshot.latest(id, "before")

    pruned = %{ctx | evaluate: fn _refs, _window, _ctx -> %{"fixture/duration" => %{"coverage" => %{"status" => "partial"}, "observations" => []}} end}
    assert {:ok, %{appended: 0}} = Checkpoint.run(id, ~U[2026-10-02 12:00:00Z], pruned)
    assert {:ok, frozen} = Snapshot.latest(id, "after")
    assert [%{"unit_id" => "saved", "value" => 500}] = frozen["metrics"]["fixture/duration"]["observations"]
    assert frozen["revision"] == 1
    assert {:ok, [%{"metric" => "fixture/duration"}]} = Checkpoint.partial(id, "after")
  end

  test "inactive experiments are skipped" do
    for status <- ["draft", "concluded", "abandoned"] do
      id = write_spec("checkpoint-#{status}", status)
      assert {:ok, %{skipped: true}} = Checkpoint.run(id, ~U[2026-10-02 12:00:00Z], %{checkpoint_evaluate: fn _, _, _ -> flunk("inactive evaluated") end})
      refute File.exists?(Paths.file(id, "snapshots"))
    end
  end

  test "a failing evaluator journals once per hour without crashing the writer", %{id: id} do
    ctx = %{context([]) | checkpoint_evaluate: fn _, _, _ -> raise "fixture failed" end}
    assert {:error, {:checkpoint_raised, "fixture failed"}} = Checkpoint.safe_run(id, ~U[2026-10-01 13:00:00Z], ctx)
    assert {:error, _reason} = Checkpoint.safe_run(id, ~U[2026-10-01 13:30:00Z], ctx)
    assert {:ok, [%{"kind" => "checkpoint_failed", "reason" => reason}]} = Journal.read(Paths.file(id, "journal.ndjson"))
    assert reason =~ "fixture failed"
    assert {:error, _reason} = Checkpoint.safe_run(id, ~U[2026-10-01 14:00:00Z], ctx)
    assert {:ok, entries} = Journal.read(Paths.file(id, "journal.ndjson"))
    assert length(entries) == 2
  end

  test "worker catches each experiment failure and reaches following experiments" do
    owner = self()

    pid =
      start_supervised!(
        {Checkpointer,
         name: nil,
         start_paused?: true,
         clock: fn -> ~U[2026-10-01 13:00:00Z] end,
         list: fn filters ->
           assert filters == [status: "active"]
           {:ok, [%{id: "bad-fixture"}, %{id: "good-fixture"}]}
         end,
         checkpoint: fn
           "bad-fixture", _now ->
             raise "broken fixture"

           "good-fixture", now ->
             send(owner, {:checkpointed, now})
             {:ok, %{}}
         end}
      )

    assert capture_log(fn ->
             send(pid, :tick)
             :sys.get_state(pid)
           end) =~ "broken fixture"

    assert_received {:checkpointed, ~U[2026-10-01 13:00:00Z]}
    assert Process.alive?(pid)
  end
end
