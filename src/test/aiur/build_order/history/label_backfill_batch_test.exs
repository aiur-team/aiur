defmodule Aiur.BuildOrder.History.LabelBackfillBatchTest do
  use ExUnit.Case, async: true
  alias Aiur.BuildOrder.History.LabelBackfill

  defmodule Tracker do
    def ensure_labels(_labels), do: :ok
    def add_label(_number, _label), do: :ok
  end

  setup do
    now = DateTime.utc_now()
    {:ok, fixture} = Agent.start_link(fn -> %{now: now, number: 1} end)
    get = fn key -> Agent.get(fixture, &Map.fetch!(&1, key)) end
    owner = %{feature: "history", confirmed: true}

    readers = %{
      tracker_supported: fn -> true end,
      features: fn -> {:ok, %{owners: %{get.(:number) => owner}}} end,
      projection: fn _ -> {:ok, %{get.(:number) => :held_backfill}} end,
      owner: fn n -> if n == get.(:number), do: {:ok, owner}, else: :none end,
      overrides: fn -> {:ok, %{}, %{state: :healthy}} end,
      settings: fn -> {:ok, %{build_order: %{general_epics: []}}} end,
      history: fn numbers ->
        {:ok, Enum.map(numbers, &%{number: &1, labels: [], lifecycle: %{state: :closed}, observed_at: get.(:now)}), %{state: :healthy}}
      end,
      health: fn -> %{state: :healthy, observed_at: get.(:now)} end,
      mark: fn _, _, _ -> :ok end
    }

    dir = Path.join(System.tmp_dir!(), "label-batch-#{System.pid()}-#{System.unique_integer([:positive])}")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)

    opts = [
      name: nil,
      repository: "o/r",
      state_path: Path.join(dir, "writes.json"),
      readers: readers,
      tracker: Tracker,
      clock: fn -> get.(:now) end,
      sync: fn -> :ok end,
      tick_ms: 3_600_000,
      budget_settings: fn -> %{agent_core_limit_per_hour: 250} end,
      max_writes_per_minute: 20,
      agent_workspace: ""
    ]

    server = start_supervised!({LabelBackfill, opts})
    %{server: server, fixture: fixture, now: now}
  end

  test "resume queued behind a paused batch lazily plans without crashing", ctx do
    LabelBackfill.start(server: ctx.server, expect: 2, per_hour: 1)
    assert %{requests_last_hour: 1} = LabelBackfill.tick(server: ctx.server)
    LabelBackfill.pause(server: ctx.server)
    Agent.update(ctx.fixture, &%{&1 | now: DateTime.add(ctx.now, 3600)})
    monitor = Process.monitor(ctx.server)
    :sys.suspend(ctx.server)
    send(ctx.server, :work)
    resume = Task.async(fn -> LabelBackfill.resume(server: ctx.server) end)
    await_call(ctx.server, :resume)
    :sys.resume(ctx.server)
    Task.await(resume)
    refute_receive {:DOWN, ^monitor, :process, _, _}, 500
    assert %{run: %{state: :finished}, counts: %{written: 1}} = LabelBackfill.tick(server: ctx.server)
  end

  test "start queued behind a completed batch skips the previous run's ids", ctx do
    LabelBackfill.start(server: ctx.server, expect: 2)
    assert %{run: %{state: :finished}} = LabelBackfill.tick(server: ctx.server)
    Agent.update(ctx.fixture, &%{&1 | number: 2})
    monitor = Process.monitor(ctx.server)
    :sys.suspend(ctx.server)
    send(ctx.server, :work)
    start = Task.async(fn -> LabelBackfill.start(server: ctx.server, expect: 2) end)
    await_call(ctx.server, {:start, [server: ctx.server, expect: 2]})
    :sys.resume(ctx.server)
    Task.await(start)
    refute_receive {:DOWN, ^monitor, :process, _, _}, 500
    assert %{run: %{state: :finished}, counts: %{written: 1}} = LabelBackfill.tick(server: ctx.server)
  end

  defp await_call(server, message, attempts \\ 1000)
  defp await_call(_server, _message, 0), do: flunk("control call was not queued")

  defp await_call(server, message, attempts) do
    {:messages, messages} = Process.info(server, :messages)

    if Enum.any?(messages, &match?({:"$gen_call", _, ^message}, &1)) do
      :ok
    else
      Process.sleep(1)
      await_call(server, message, attempts - 1)
    end
  end
end
