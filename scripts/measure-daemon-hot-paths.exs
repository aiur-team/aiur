# Run from src/: mix run --no-compile --no-start ../scripts/measure-daemon-hot-paths.exs SOURCE_CHECKOUT
# Each invocation uses a fresh VM. Overlay the exact source revision under test
# on the head's compiled dependency artifacts; no daemon or live state is read.
[source_root] = System.argv()
{revision, 0} = System.cmd("git", ["-C", source_root, "rev-parse", "HEAD"])
IO.puts("SOURCE #{String.trim(revision)}")
Code.compiler_options(ignore_module_conflict: true)

for relative <- [
      "ticket_activity/projection.ex",
      "ticket_activity.ex",
      "current_run_projections/checkpoint.ex",
      "current_run_projections/checkpoint_persistence.ex",
      "current_run_membership/store/recovery.ex",
      "current_run_membership/store/runtime.ex",
      "current_run_membership/store/batch.ex",
      "current_run_membership/store.ex",
      "current_run_membership/reconciler/snapshot.ex",
      "current_run_membership/reconciler.ex"
    ] do
  path = Path.join([source_root, "src/lib/aiur", relative])
  if File.regular?(path), do: Code.compile_file(path)
end

defmodule DaemonHotPathMeasurement do
  alias Aiur.CurrentRunMembership.{Reconciler, Store}
  alias Aiur.CurrentRunProjections.{Checkpoint, CheckpointPersistence}
  alias Aiur.{TicketActivity, TrackerIdentity}

  def run do
    {:ok, _} = Application.ensure_all_started(:crypto)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    {:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: Aiur.PubSub)
    activity()
    checkpoint()
    membership()
  end

  defp activity do
    now = DateTime.utc_now()
    members = Enum.map(1..200, &identity/1)
    retained = Map.new(members, &{&1.provider_id, %{identity: &1, progress: %{percent: 40, observed_at: now}}})

    {:ok, owner} =
      TicketActivity.start_link(
        name: nil,
        now_fun: fn -> now end,
        membership_snapshot_fun: fn -> %{members: members} end,
        exchange_subscribe_fun: fn -> :ok end,
        membership_subscribe_fun: fn -> :ok end,
        retention_all_fun: fn -> retained end
      )

    200 = length(TicketActivity.snapshots(server: owner, now: now).entries)
    patterns = [{TrackerIdentity, :github_key, 1}, {TrackerIdentity, :joinable?, 1}]
    trace(owner, patterns)
    send(owner, {:current_run_membership_health_changed, %{}})
    200 = length(TicketActivity.snapshots(server: owner, now: now).entries)
    report("activity_health_scan_and_snapshots members=200", owner, patterns)
    GenServer.stop(owner)
  end

  defp checkpoint do
    parent = self()

    owner =
      spawn_link(fn ->
        facts = Map.new(1..1_000, &{{:github, "owner", "repo", to_string(&1)}, %{weight: &1}})
        candidate = %{run_id: "measurement", checkpoint_generation: 1, weight_facts: facts}
        send(parent, {:ready, self()})

        receive do
          :go ->
            dump = Checkpoint.dump(candidate)
            1_000 = map_size(dump.weight_facts)
            hash = CheckpointPersistence.content_hash(dump)
            32 = byte_size(hash)
            send(parent, {:done, self()})
        end

        receive do
          :stop -> :ok
        end
      end)

    receive do
      {:ready, ^owner} -> :ok
    end

    patterns = [{Kernel, :inspect, 1}, {Kernel, :inspect, 2}]
    trace(owner, patterns)
    send(owner, :go)

    receive do
      {:done, ^owner} -> :ok
    end

    report("checkpoint_dump_and_hash weight_facts=1000", owner, patterns)
    send(owner, :stop)
  end

  defp membership do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    dir = Path.join(System.tmp_dir!(), "membership-measurement-#{suffix}")
    false = File.exists?(dir)
    {:ok, store} = Store.start_link(state_dir: dir, run_id: "measurement", checkpoint_interval: 32, event_publish_fun: fn _, _ -> :ok end)
    0 = Store.generation(store)
    patterns = [{:file, :open, 2}, {:file, :sync, 1}]
    trace(store, patterns)
    parent = self()
    rows = for id <- 1..3, do: %{tracker_identity: identity(id)}

    {:ok, reconciler} =
      Reconciler.start_link(
        name: nil,
        snapshot_fun: fn -> %{running: rows} end,
        terminal_states_fun: &MapSet.new/0,
        subscribe_fun: fn -> :ok end,
        membership_subscribe_fun: fn -> :ok end,
        reconciliation_fun: fn status -> send(parent, {:reconciled, status}) end,
        reconcile_interval_ms: :infinity
      )

    receive do
      {:reconciled, :fresh} -> :ok
    end

    3 = Store.generation(store)
    report("default_reconciler changed_rows=3", store, patterns)
    GenServer.stop(reconciler)
    GenServer.stop(store)
    # The exact per-VM path remains in the workspace-private TMPDIR as evidence.
  end

  defp identity(id) do
    %TrackerIdentity{status: :joinable, kind: :github, owner: "Owner", repository: "Repo", provider_id: to_string(id), identifier: to_string(id), reason: nil}
  end

  defp trace(owner, patterns) do
    for {module, _, _} = pattern <- patterns do
      Code.ensure_loaded!(module)
      count = :erlang.trace_pattern(pattern, true, [])
      if count == 0, do: raise("trace pattern did not attach")
    end

    :erlang.trace(owner, true, [:call])
  end

  defp report(label, owner, patterns) do
    ref = :erlang.trace_delivered(owner)

    receive do
      {:trace_delivered, ^owner, ^ref} -> :ok
    end

    calls = drain(owner, [])

    counts =
      Enum.map(patterns, fn {module, function, arity} = pattern ->
        :erlang.trace_pattern(pattern, false, [])
        count = Enum.count(calls, fn {m, f, args} -> m == module and f == function and length(args) == arity end)
        {"#{module}.#{function}/#{arity}", count}
      end)

    IO.puts("MEASUREMENT #{label}: #{inspect(counts)}")
  end

  defp drain(owner, acc) do
    receive do
      {:trace, ^owner, :call, call} -> drain(owner, [call | acc])
    after
      0 -> acc
    end
  end
end

DaemonHotPathMeasurement.run()
