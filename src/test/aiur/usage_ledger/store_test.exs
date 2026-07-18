defmodule Aiur.UsageLedger.StoreTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias Aiur.UsageLedger
  alias Aiur.UsageLedger.{Checkpoint, Recovery, Store}
  import Aiur.TestSupport.UsageLedger, only: [envelope: 1, money: 2]

  defmodule BackendStub do
    @behaviour Aiur.UsageLedger

    @impl true
    def append(_envelope), do: {:ok, %{position: 7, generation: 11, delta: %{tokens: %{input: 3}}}}

    @impl true
    def scan(_options), do: {:ok, []}

    @impl true
    def retire(_watermark), do: {:ok, %{retired_through: 0, retired_count: 0}}

    @impl true
    def health, do: :healthy

    @impl true
    def generation, do: 11

    @impl true
    def coverage, do: %{lower: 7, upper: 7, status: :full}

    @impl true
    def subscribe(_pid), do: :ok

    @impl true
    def child_spec(_opts),
      do: %{
        id: __MODULE__,
        start:
          {Task, :start_link,
           [
             fn ->
               receive do
                 :stop -> :ok
               end
             end
           ]}
      }
  end

  setup do
    root = Path.join(System.tmp_dir!(), "aiur-usage-ledger-#{System.unique_integer([:positive])}")
    name = String.to_atom("usage_ledger_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, name: name}
  end

  test "acknowledges only after append and checkpoint, then survives restart without re-adding cumulative input", %{root: root, name: name} do
    {:ok, pid} = start_store(root, name)
    :ok = subscribe(name, self())
    first = envelope(%{tokens: token_values(10)})

    assert {:ok, acknowledgement} = append(name, first)
    assert acknowledgement.position == 1
    assert acknowledgement.delta.relationship_revision == "codex-app-server-2026-07"
    assert_receive {:usage_ledger_delta, ^acknowledgement}
    GenServer.stop(pid)

    {:ok, restarted} = start_store(root, name)
    assert {:ok, [record]} = scan(name)
    assert record.delta.relationship_revision == "codex-app-server-2026-07"
    assert {:duplicate, duplicate} = append(name, first)
    assert duplicate.position == acknowledgement.position

    changed_retry =
      envelope(%{
        idempotency_key: first.idempotency_key,
        source_event_id: "changed-event-id",
        source_sequence: 18,
        source_version: "2026-08",
        requested_model: "gpt-5.7-terra",
        resolved_model: "gpt-5.7-terra",
        tokens: token_values(999),
        relationship_revision: "codex-app-server-2026-08",
        cost: money("9.99", :absolute)
      })

    assert {:duplicate, durable_duplicate} = append(name, changed_retry)
    assert durable_duplicate.position == acknowledgement.position
    refute_receive {:usage_ledger_delta, _}
    GenServer.stop(restarted)
  end

  test "prevents runtime configuration from redirecting the supervised backend" do
    previous = Application.get_env(:aiur, :usage_ledger_backend)
    Application.put_env(:aiur, :usage_ledger_backend, BackendStub)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:aiur, :usage_ledger_backend, previous),
        else: Application.delete_env(:aiur, :usage_ledger_backend)
    end)

    assert 0 = UsageLedger.generation()
    assert :healthy = UsageLedger.health()
    assert %{status: :empty} = UsageLedger.coverage()
  end

  test "path resolution failure stays unavailable without preparing the current directory", %{
    root: root,
    name: name
  } do
    cwd = Path.join(root, "cwd")
    File.mkdir_p!(cwd)
    original_mode = File.stat!(cwd).mode
    original_instance_key = System.get_env("AIUR_INSTANCE_KEY")
    original_ledger_dir = Application.get_env(:aiur, :usage_ledger_state_dir)
    original_decision_dir = Application.get_env(:aiur, :decision_state_dir)

    on_exit(fn ->
      restore_system_env("AIUR_INSTANCE_KEY", original_instance_key)
      restore_application_env(:usage_ledger_state_dir, original_ledger_dir)
      restore_application_env(:decision_state_dir, original_decision_dir)
      :erlang.trace(:new, false, [:call])
      :erlang.trace_pattern({Recovery, :boot, 2}, false, [:local])
    end)

    System.delete_env("AIUR_INSTANCE_KEY")
    Application.delete_env(:aiur, :usage_ledger_state_dir)
    Application.delete_env(:aiur, :decision_state_dir)
    :erlang.trace_pattern({Recovery, :boot, 2}, true, [:local])
    :erlang.trace(:new, true, [:call, {:tracer, self()}])

    File.cd!(cwd, fn ->
      assert {:ok, pid} = Store.start_link(name: name)
      assert {:unavailable, :missing_instance_key} = health(name)
      assert File.ls!(cwd) == []
      assert File.stat!(cwd).mode == original_mode
      refute_received {:trace, ^pid, :call, {Recovery, :boot, _arguments}}
      GenServer.stop(pid)
    end)
  end

  test "never acknowledges or publishes an injected append/checkpoint failure", %{root: root, name: name} do
    {:ok, pid} =
      start_store(root, name,
        append_fun: fn _path, _record -> {:error, :enospc} end,
        publish_fun: fn acknowledgement -> send(self(), {:published, acknowledgement}) end
      )

    assert {:error, :persistence_failed} = append(name, envelope(%{}))
    refute_receive {:published, _}
    assert {:degraded, :persistence_failed} = health(name)
    GenServer.stop(pid)
  end

  test "recovers one uncheckpointed canonical append after a checkpoint failure without a second delta", %{root: root, name: name} do
    {:ok, pid} =
      start_store(root, name, checkpoint_fun: fn _path, _checkpoint -> {:error, :eio} end)

    first = envelope(%{})
    assert {:error, :persistence_failed} = append(name, first)
    GenServer.stop(pid)

    {:ok, restarted} = start_store(root, name)
    assert {:ok, [record]} = scan(name)
    assert record.delta.tokens.input == 10
    assert {:duplicate, duplicate} = append(name, first)
    assert duplicate.position == record.position
    GenServer.stop(restarted)
  end

  test "fails closed at the durable idempotency capacity without evicting the validated prefix", %{root: root, name: name} do
    {:ok, pid} = start_store(root, name, limits: [max_idempotency_entries: 1])
    first = envelope(%{})

    second =
      envelope(%{
        idempotency_key: "codex:evt-18",
        source_event_id: "evt-18",
        source_sequence: 18,
        tokens: token_values(11),
        cost: money("1.10", :absolute)
      })

    assert {:ok, _first} = append(name, first)
    assert {:error, :capacity_exhausted} = append(name, second)
    assert {:ok, [record]} = scan(name)
    assert record.envelope.idempotency_key == first.idempotency_key
    assert {:degraded, :capacity_exhausted} = health(name)
    GenServer.stop(pid)
  end

  test "keeps canonical state owner-only and rejects content-bearing envelopes before append", %{root: root, name: name} do
    {:ok, pid} = start_store(root, name)

    unsafe = envelope(%{source: "/provider/raw-response"})
    assert {:error, :content_rejected} = append(name, unsafe)
    assert {:ok, _acknowledgement} = append(name, envelope(%{}))

    for path <- [root, Path.join(root, "segments"), Path.join([root, "segments", "00000001.ndjson"]), Path.join(root, "checkpoint.json")] do
      assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
      assert (mode &&& 0o077) == 0, "#{Path.basename(path)} must be owner-only"
    end

    refute File.read!(Path.join([root, "segments", "00000001.ndjson"])) =~ "raw-response"
    GenServer.stop(pid)
  end

  test "persists partial raw coverage across checkpoint and process restart", %{root: root, name: name} do
    {:ok, pid} = start_store(root, name)

    assert {:ok, _acknowledgement} = append(name, envelope(%{update_kind: :partial}))
    assert %{status: :partial} = coverage(name)
    GenServer.stop(pid)

    {:ok, restarted} = start_store(root, name)
    assert %{status: :partial} = coverage(name)
    GenServer.stop(restarted)
  end

  test "the public durable call remains pending until the checkpoint is durable", %{
    root: root,
    name: name
  } do
    assert Store.durability_timeout() == :infinity
    parent = self()

    checkpoint_fun = fn path, checkpoint ->
      send(parent, {:checkpoint_waiting, self()})

      receive do
        :continue_checkpoint -> Checkpoint.overwrite_encoded(path, checkpoint)
      end
    end

    {:ok, pid} = start_store(root, name, checkpoint_fun: checkpoint_fun)

    next =
      envelope(%{
        idempotency_key: "codex:evt-18",
        source_event_id: "evt-18",
        source_sequence: 18,
        tokens: token_values(11)
      })

    task = Task.async(fn -> Store.append(name, next) end)
    assert_receive {:checkpoint_waiting, checkpoint_owner}, 2_000
    assert Task.yield(task, 100) == nil
    send(checkpoint_owner, :continue_checkpoint)
    assert {:ok, {:ok, %{position: 1}}} = Task.yield(task, 2_000)
    GenServer.stop(pid)
  end

  test "hot appends never invoke the recovery-only filesystem barrier", %{root: root, name: name} do
    {:ok, prepared} = start_store(root, name)
    GenServer.stop(prepared)
    parent = self()

    sync_fun = fn ->
      send(parent, :global_sync_called)
      {:error, :global_sync_called}
    end

    {:ok, pid} = start_store(root, name, filesystem_sync_fun: sync_fun)

    assert {:ok, %{position: 1}} = append(name, envelope(%{}))
    refute_received :global_sync_called
    GenServer.stop(pid)
  end

  test "the durability timeout accepts only explicit positive overrides" do
    previous = Application.get_env(:aiur, :usage_ledger_durability_timeout)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:aiur, :usage_ledger_durability_timeout)
        value -> Application.put_env(:aiur, :usage_ledger_durability_timeout, value)
      end
    end)

    Application.put_env(:aiur, :usage_ledger_durability_timeout, 30_000)
    assert Store.durability_timeout() == 30_000

    Application.put_env(:aiur, :usage_ledger_durability_timeout, 0)
    assert Store.durability_timeout() == :infinity
  end

  test "rejects huge integers before append serialization", %{root: root, name: name} do
    parent = self()

    {:ok, pid} =
      start_store(root, name,
        append_fun: fn _path, _record ->
          send(parent, :append_reached)
          :ok
        end
      )

    huge_integer = 1 <<< 100_000
    oversized = envelope(%{tokens: token_values(huge_integer)})

    assert {:error, :numeric_value_out_of_bounds} = append(name, oversized)
    refute_received :append_reached
    assert {:ok, []} = scan(name)
    GenServer.stop(pid)
  end

  test "encodes each candidate checkpoint once and retains records in an append-efficient queue", %{
    root: root,
    name: name
  } do
    parent = self()

    encode_fun = fn checkpoint, max_bytes ->
      send(parent, {:checkpoint_encoded, checkpoint["position"]})
      Checkpoint.encode(checkpoint, max_bytes)
    end

    {:ok, pid} = start_store(root, name, checkpoint_encode_fun: encode_fun)

    Enum.each(1..32, fn offset ->
      measurement =
        envelope(%{
          idempotency_key: "codex:scaling-#{offset}",
          source_event_id: "scaling-#{offset}",
          source_sequence: 17 + offset,
          tokens: token_values(10 + offset),
          cost: nil
        })

      assert {:ok, %{position: ^offset}} = append(name, measurement)
    end)

    encoded_positions =
      Enum.map(1..32, fn _offset ->
        assert_receive({:checkpoint_encoded, position}, 2_000)
        position
      end)

    assert encoded_positions == Enum.to_list(1..32)
    assert :queue.len(:sys.get_state(name).records) == 32
    GenServer.stop(pid)
  end

  defp start_store(root, name, opts \\ []) do
    Store.start_link(Keyword.merge([name: name, state_dir: root, filesystem_sync_fun: fn -> :ok end], opts))
  end

  defp append(server, envelope), do: GenServer.call(server, {:append, envelope})
  defp scan(server), do: GenServer.call(server, {:scan, []})
  defp health(server), do: GenServer.call(server, :health)
  defp coverage(server), do: GenServer.call(server, :coverage)
  defp subscribe(server, pid), do: GenServer.call(server, {:subscribe, pid})

  defp token_values(input) do
    %{
      input: input,
      cached_input: nil,
      cache_creation_input: nil,
      output: nil,
      reasoning_output: nil,
      provider_reported_total: nil
    }
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_application_env(key, value), do: Application.put_env(:aiur, key, value)
  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
