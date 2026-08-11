defmodule Aiur.WorkflowStoreReadPathTest do
  @moduledoc """
  Regression for #1731.

  `Aiur.Orchestrator` was caught with a 10,456-message mailbox, itself blocked in
  `gen:do_call/4` inside `Aiur.WorkflowStore.current_from/1`, reached from
  `Aiur.Config.settings/0` on the backend-override hot path. The store was
  running a regex at that instant — it re-read and re-parsed the config on every
  single call. `erlang:statistics(:run_queue)` was 1: the machine was idle and
  one process was head-of-line blocked behind another.

  These tests pin the property that makes that impossible: reading the config
  does not enter the store's mailbox at all.
  """

  use Aiur.TestSupport

  alias Aiur.Config.Schema

  setup do
    ensure_workflow_store_running()
    :ok
  end

  test "config reads never enter the WorkflowStore mailbox" do
    store = Process.whereis(WorkflowStore)

    # Keep the fallback timeout short so this test still finishes quickly when
    # the property is broken — the failure signal is the queued messages below,
    # not the wall clock.
    Application.put_env(:aiur, :workflow_store_call_timeout_ms, 10)
    :sys.suspend(store)

    on_exit(fn ->
      if Process.alive?(store), do: :sys.resume(store)
      Application.delete_env(:aiur, :workflow_store_call_timeout_ms)
    end)

    for _ <- 1..100 do
      assert %Schema{} = Config.settings!()
    end

    # A suspended process drains nothing, so anything the read path sent is
    # still sitting here. Before the fix this was 100 `:current` calls; a real
    # daemon with a busy store queues them behind every other caller.
    assert {:message_queue_len, 0} = Process.info(store, :message_queue_len)
  end

  test "a stalled store does not serialize concurrent readers" do
    store = Process.whereis(WorkflowStore)
    Application.put_env(:aiur, :workflow_store_call_timeout_ms, 200)
    :sys.suspend(store)

    on_exit(fn ->
      if Process.alive?(store), do: :sys.resume(store)
      Application.delete_env(:aiur, :workflow_store_call_timeout_ms)
    end)

    readers = 8
    reads_per_reader = 10

    {elapsed_us, _} =
      :timer.tc(fn ->
        1..readers
        |> Enum.map(fn _ ->
          Task.async(fn -> for _ <- 1..reads_per_reader, do: Config.settings!() end)
        end)
        |> Task.await_many(30_000)
      end)

    elapsed_ms = div(elapsed_us, 1_000)

    # Serialized, each of the 80 reads costs the full 200ms call timeout, so the
    # floor is 10 * 200ms = 2s of wall clock (and on the live daemon, with the
    # store merely busy rather than suspended, it is unbounded). Reading through
    # ETS, none of them wait on anyone. The bound is deliberately loose — this
    # asserts "not serialized", not a specific speed.
    assert elapsed_ms < 500, "concurrent config reads took #{elapsed_ms}ms; expected no serialization"
  end

  test "reads see a config change on the next read after a reload" do
    path = Workflow.workflow_file_path()
    root = Path.join(Path.dirname(path), "workspaces-read-path")

    write_workflow_file!(path, workspace_root: root)

    assert Config.workspace_root() == root
  end

  test "the parsed-settings memo is invalidated by an environment change" do
    # `Schema.parse/1` resolves `$ENV` references at parse time, so the memo
    # cannot be keyed on the config generation alone.
    var = "AIUR_TEST_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    path = Workflow.workflow_file_path()
    first = Path.join(System.tmp_dir!(), "aiur-env-first-#{System.unique_integer([:positive])}")
    second = Path.join(System.tmp_dir!(), "aiur-env-second-#{System.unique_integer([:positive])}")

    System.put_env(var, first)
    on_exit(fn -> System.delete_env(var) end)

    write_workflow_file!(path, workspace_root: "$" <> var)

    assert Config.workspace_root() == first

    System.put_env(var, second)

    assert Config.workspace_root() == second
  end

  # The epoch samples only the variables the parse can consult, so the ones it
  # reads without the config naming them have to be sampled explicitly. Missing
  # one freezes a resolved secret for the life of the config — silently, since
  # every other read keeps working.
  test "the parsed-settings memo is invalidated by a secret the config never names" do
    previous = System.get_env("LINEAR_API_KEY")

    on_exit(fn ->
      if previous, do: System.put_env("LINEAR_API_KEY", previous), else: System.delete_env("LINEAR_API_KEY")
    end)

    # No `api_key:` in the config, so `LINEAR_API_KEY` is the only source — and
    # nothing in the file names it, which is the case a config-derived
    # dependency set would miss.
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)

    System.put_env("LINEAR_API_KEY", "key-first")
    assert Config.settings!().tracker.linear.api_key == "key-first"

    System.put_env("LINEAR_API_KEY", "key-rotated")
    assert Config.settings!().tracker.linear.api_key == "key-rotated"
  end

  # Not a pass/fail assertion — a measurement, excluded by default (the suite
  # excludes `:perf_regression`). Run with
  # `mix test test/aiur/workflow_store_read_path_test.exs --include perf_regression --only perf_regression`
  # to reproduce the throughput and scaling numbers quoted in #1731.
  @tag :perf_regression
  @tag timeout: 300_000
  test "bench: Config.settings/0 throughput against a healthy store" do
    reads = 500

    single =
      measure_ms(fn ->
        for _ <- 1..reads, do: Config.settings!()
      end)

    for concurrency <- [1, 2, 4, 8, 16] do
      elapsed =
        measure_ms(fn ->
          1..concurrency
          |> Enum.map(fn _ -> Task.async(fn -> for _ <- 1..reads, do: Config.settings!() end) end)
          |> Task.await_many(300_000)
        end)

      IO.puts(
        "concurrency=#{concurrency} reads=#{concurrency * reads} elapsed=#{elapsed}ms " <>
          "per_read=#{Float.round(elapsed / (concurrency * reads), 4)}ms"
      )
    end

    IO.puts("serial baseline: #{reads} reads in #{single}ms")
  end

  defp measure_ms(fun) do
    {us, _} = :timer.tc(fun)
    div(us, 1_000)
  end

  test "a store restart drops the cache rather than serving a dead generation" do
    store = Process.whereis(WorkflowStore)
    assert %Schema{} = Config.settings!()

    ref = Process.monitor(store)
    Process.exit(store, :kill)
    assert_receive {:DOWN, ^ref, :process, ^store, :killed}, 5_000

    # The table is owned by the store, so it dies with it and the read path
    # falls back to the file instead of serving a stale entry.
    assert %Schema{} = Config.settings!()

    ensure_workflow_store_running()
    assert %Schema{} = Config.settings!()
  end
end
