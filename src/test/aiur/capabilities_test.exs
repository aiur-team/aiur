defmodule Aiur.CapabilitiesTest do
  # One fixture family exercises the registry, provider failures and read path together.
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Aiur.TestSupport, only: [receive_barrier: 1]
  alias Aiur.Capabilities
  alias Aiur.Capabilities.{Monitor, Table}

  defmodule FakeProvider do
    @behaviour Aiur.Capabilities.Provider
    @impl true
    def capability_ids, do: ["test.fake"]
    @impl true
    def capabilities(context) do
      Agent.get(__MODULE__, fn {state, owner} ->
        send(owner, {:context, context})
        %{"test.fake" => %{state: state, reason: if(state == :available, do: nil, else: :disabled)}, "undeclared" => %{state: :available}}
      end)
    end

    @impl true
    def sections(_context), do: %{repository: %{kind: "memory", owner: nil, name: "memory"}}
  end

  defmodule HungProvider do
    @behaviour Aiur.Capabilities.Provider
    @impl true
    def capability_ids, do: ["test.hung"]
    @impl true
    def capabilities(_context) do
      receive do
        :never -> %{}
      end
    end
  end

  defmodule RaisingProvider do
    @behaviour Aiur.Capabilities.Provider
    @impl true
    def capability_ids, do: ["test.raising"]
    @impl true
    def capabilities(_context), do: raise("failed")
    @impl true
    def sections(_context), do: %{executor: %{state: :active}}
  end

  defmodule DuplicateProvider do
    @behaviour Aiur.Capabilities.Provider
    @impl true
    def capability_ids, do: ["test.fake"]
    @impl true
    def capabilities(_context), do: %{"test.fake" => %{state: :available}}
  end

  setup do
    owner = self()
    start_supervised!(%{id: FakeProvider, start: {Agent, :start_link, [fn -> {:available, owner} end, [name: FakeProvider]]}})
    table = String.to_atom("capabilities_test_#{System.unique_integer([:positive])}")
    start_supervised!({Table, table: table, name: nil})
    %{table: table, opts: [table: table, providers: [FakeProvider], now_fun: fn -> 10_000 end]}
  end

  defp monitor(opts) do
    pid = start_supervised!({Monitor, opts ++ [name: nil, tick_ms: 60_000]})
    :sys.get_state(pid)
    pid
  end

  defp tick(pid) do
    send(pid, :tick)
    :sys.get_state(pid)
  end

  test "revision increments only when capability entries change", %{opts: opts} do
    pid = monitor(opts)
    first = Capabilities.report(opts)
    assert first.revision == 1
    tick(pid)
    assert Capabilities.report(opts).revision == first.revision
    Agent.update(FakeProvider, fn {_state, owner} -> {:unavailable, owner} end)
    tick(pid)
    changed = Capabilities.report(opts)
    assert changed.revision == first.revision + 1
    assert changed.capabilities["test.fake"] == %{state: :unavailable, reason: :disabled}
  end

  test "revision and report survive monitor restart", %{opts: opts} do
    pid = monitor(opts)
    Agent.update(FakeProvider, fn {_state, owner} -> {:unavailable, owner} end)
    tick(pid)
    before = Capabilities.report(opts)
    assert before.revision == 2
    stop_supervised!(Monitor)
    assert Capabilities.report(opts) == before
    restarted = monitor(opts)
    assert Capabilities.report(opts).revision == before.revision
    Agent.update(FakeProvider, fn {_state, owner} -> {:available, owner} end)
    tick(restarted)
    assert Capabilities.report(opts).revision == before.revision + 1
  end

  test "hung provider becomes unknown within budget without losing other providers", %{opts: opts} do
    opts = Keyword.put(opts, :providers, [HungProvider, FakeProvider])
    began = System.monotonic_time(:millisecond)
    monitor(opts)
    assert System.monotonic_time(:millisecond) - began < 1_000
    caps = Capabilities.report(opts).capabilities
    assert caps["test.hung"] == %{state: :unknown, reason: :unknown}
    assert caps["test.fake"].state == :available
  end

  test "raising provider is unknown with nil sections and logs only on state transition", %{opts: opts} do
    opts = Keyword.put(opts, :providers, [RaisingProvider])

    log =
      capture_log(fn ->
        pid = monitor(opts)
        tick(pid)
        report = Capabilities.report(opts)
        assert report.capabilities["test.raising"] == %{state: :unknown, reason: :unknown}
        assert report.executor == nil
        assert report.repository == nil
      end)

    assert length(Regex.scan(~r/capability_registry.*failed/, log)) == 1
  end

  test "undeclared IDs are dropped and sections and context come from providers", %{opts: opts} do
    monitor(opts)
    report = Capabilities.report(opts)
    refute Map.has_key?(report.capabilities, "undeclared")
    assert report.repository == %{kind: "memory", owner: nil, name: "memory"}
    {:context, %{run_shape: shape, settings: settings}} = receive_barrier({:context, _context})
    assert shape == report.instance.run_shape
    assert is_struct(settings, Aiur.Config.Schema)
  end

  test "duplicate ID is unknown regardless of provider order", %{opts: opts} do
    for providers <- [[FakeProvider, DuplicateProvider], [DuplicateProvider, FakeProvider]] do
      report = Capabilities.report(Keyword.put(opts, :providers, providers))
      assert report.capabilities["test.fake"] == %{state: :unknown, reason: :unknown}
    end
  end

  test "known IDs without providers are not installed; dynamic unknown IDs stay absent", %{opts: opts} do
    report = Capabilities.report(Keyword.put(opts, :providers, []))
    assert report.capabilities["api.http"] == %{state: :unavailable, reason: :not_installed}
    assert report.capabilities["build_queue.build_order_source"] == %{state: :unavailable, reason: :not_installed}
    refute Map.has_key?(report.capabilities, "harness.<id>.native_question")
  end

  test "age and freshness are computed at read time using monotonic clock", %{opts: opts} do
    monitor(opts)
    current = Capabilities.report(Keyword.put(opts, :now_fun, fn -> 16_000 end))
    assert current.age_ms == 6_000
    assert current.freshness == "current"
    stale = Capabilities.report(Keyword.put(opts, :now_fun, fn -> 17_000 end))
    assert stale.age_ms == 7_000
    assert stale.freshness == "stale"
    assert stale.observed_at == current.observed_at
    assert {:ok, _time, 0} = DateTime.from_iso8601(stale.observed_at)
  end

  test "boot ID and identity sections are read from the real kernel facade", %{opts: opts} do
    opts = Keyword.put(opts, :providers, [Aiur.Capabilities.IdentityProvider])
    monitor(opts)
    report = Capabilities.report(opts)
    assert report.boot_id == Aiur.Boot.run_id()
    assert report.contract == "aiur.capabilities"
    assert report.contract_version == 1
    assert report.min_client_versions == %{}
    assert {:ok, machine} = Aiur.Identity.machine()
    assert report.machine == machine
    assert report.instance == Aiur.Identity.instance_section()
    assert report.capabilities["identity"] == Aiur.Identity.identity_capability()
  end

  test "unpublished report computes synchronously without writing revision", %{table: table, opts: opts} do
    report = Capabilities.report(opts)
    assert report.revision == 0
    assert report.capabilities["test.fake"].state == :available
    assert report.freshness == "current"
    assert :ets.tab2list(table) == []
  end

  test "missing table computes synchronously with explicitly stale freshness", %{table: table, opts: opts} do
    stop_supervised!(Table)
    assert :ets.whereis(table) == :undefined
    report = Capabilities.report(opts)
    assert report.revision == 0
    assert report.freshness == "stale"
    assert report.capabilities["test.fake"].state == :available
  end

  test "unreadable config is explicitly unavailable to providers", %{opts: opts} do
    original = Aiur.Workflow.workflow_file_path()
    missing = Path.join(System.tmp_dir!(), "missing-capability-config-#{System.unique_integer([:positive])}")

    try do
      Aiur.Workflow.set_workflow_file_path(missing, reload: false)
      assert {:error, _reason} = Aiur.Config.settings()
      Capabilities.report(opts)
      {:context, context} = receive_barrier({:context, _context})
      assert context.settings == :unavailable
    after
      Aiur.Workflow.set_workflow_file_path(original, reload: false)
    end
  end

  test "refresh cast recomputes without waiting for the timer", %{opts: opts} do
    pid = monitor(opts)
    Agent.update(FakeProvider, fn {_state, owner} -> {:unavailable, owner} end)
    GenServer.cast(pid, :refresh)
    :sys.get_state(pid)
    assert Capabilities.report(opts).capabilities["test.fake"].state == :unavailable
    assert Capabilities.refresh() == :ok
  end

  @tag timeout: 5_000
  test "periodic scheduling recomputes after the initial report", %{opts: opts} do
    monitor(Keyword.put(opts, :tick_ms, 0))
    receive_barrier({:context, _first})
    receive_barrier({:context, _next})
    stop_supervised!(Monitor)
  end
end
