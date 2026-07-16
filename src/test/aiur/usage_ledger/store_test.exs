defmodule Aiur.UsageLedger.StoreTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias Aiur.UsageLedger
  alias Aiur.UsageLedger.Store
  import Aiur.TestSupport.UsageLedger, only: [envelope: 1, money: 2]

  defmodule BackendStub do
    @behaviour Aiur.UsageLedger

    @impl true
    def append(_envelope), do: {:ok, %{position: 7, generation: 11, delta: %{tokens: %{input: 3}}}}

    @impl true
    def scan(_options), do: {:ok, []}

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
    first = envelope(%{tokens: %{input: 10, cached_input: nil, cache_creation_input: nil, output: nil, reasoning_output: nil, provider_reported_total: nil}})

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
      start_store(root, name, checkpoint_fun: fn _path, _checkpoint, _opts -> {:error, :eio} end)

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
        tokens: %{input: 11, cached_input: nil, cache_creation_input: nil, output: nil, reasoning_output: nil, provider_reported_total: nil},
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

  defp start_store(root, name, opts \\ []) do
    Store.start_link(Keyword.merge([name: name, state_dir: root, filesystem_sync_fun: fn -> :ok end], opts))
  end

  defp append(server, envelope), do: GenServer.call(server, {:append, envelope})
  defp scan(server), do: GenServer.call(server, {:scan, []})
  defp health(server), do: GenServer.call(server, :health)
  defp subscribe(server, pid), do: GenServer.call(server, {:subscribe, pid})
end
