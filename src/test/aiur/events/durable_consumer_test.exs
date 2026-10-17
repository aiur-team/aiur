defmodule Aiur.Events.DurableConsumerTest do
  use ExUnit.Case, async: true

  alias Aiur.Events.DurableConsumer
  alias Aiur.Events.DurableConsumer.JournalSource
  alias Aiur.Events.Journal

  defmodule FakeDurableSource do
    @behaviour Aiur.Events.DurableConsumer.Source

    def start(records), do: Agent.start_link(fn -> %{records: records, consumers: [], fail: 0, reset_below: nil, during: nil} end)
    def push_live(agent, pos), do: Agent.update(agent, &publish(&1, pos))
    def fail_next_replay(agent, n), do: Agent.update(agent, &%{&1 | fail: n})
    def reset_below(agent, n), do: Agent.update(agent, &%{&1 | reset_below: n})
    def push_during_replay(agent, pos), do: Agent.update(agent, &%{&1 | during: pos})

    defp publish(s, pos) do
      rec = %{"seq" => pos}
      Enum.each(s.consumers, &send(&1, {:durable_record, rec}))
      %{s | records: s.records ++ [rec]}
    end

    @impl true
    def subscribe(agent, consumer), do: Agent.update(agent, &%{&1 | consumers: [consumer | &1.consumers]})

    @impl true
    def replay(agent, cursor, limit) do
      s = Agent.get(agent, & &1)

      cond do
        s.fail > 0 ->
          Agent.update(agent, &%{&1 | fail: &1.fail - 1})
          {:error, :boom}

        s.reset_below && cursor + 1 < s.reset_below ->
          {:reset, s.reset_below}

        true ->
          # The record is published after this snapshot, like a live write during replay.
          if s.during, do: Agent.update(agent, &%{publish(&1, &1.during) | during: nil})
          {:ok, s.records |> Enum.filter(&(&1["seq"] > cursor)) |> Enum.take(limit)}
      end
    end

    @impl true
    def position(record), do: record["seq"]
  end

  defmodule TestHandler do
    @behaviour Aiur.Events.DurableConsumer.Handler

    # kill_at/fail_at fire once, gated by the `once` Agent.
    @impl true
    def handle_record(%{"seq" => pos}, %{test: test, once: once} = state) do
      if pos == state.fail_at and Agent.get_and_update(once, &{&1, false}) do
        {:error, :nope}
      else
        send(test, {:handled, pos})
        if pos == state.kill_at and Agent.get_and_update(once, &{&1, false}), do: Process.exit(self(), :kill)
        {:ok, state}
      end
    end

    @impl true
    def handle_reset(oldest, %{test: test} = state), do: send(test, {:reset, oldest}) && {:ok, state}

    @impl true
    def handle_unavailable(reason, %{test: test} = state), do: send(test, {:unavailable, reason}) && {:ok, state}
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "durable-consumer-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    {:ok, once} = Agent.start_link(fn -> true end)
    {:ok, dir: dir, cursor_path: Path.join(dir, "cursor.json"), once: once}
  end

  defp records(range), do: Enum.map(range, &%{"seq" => &1})
  defp write_cursor(ctx, n), do: File.write!(ctx.cursor_path, ~s({"cursor":#{n}}))
  defp read_cursor(ctx), do: ctx.cursor_path |> File.read!() |> Jason.decode!() |> Map.fetch!("cursor")

  defp start(ctx, source, extra \\ %{}, opts \\ []) do
    hs = Map.merge(%{test: self(), once: ctx.once, kill_at: nil, fail_at: nil}, extra)

    start_supervised!(
      {DurableConsumer,
       [name: :"dc_#{System.unique_integer([:positive])}", source: source, handler: {TestHandler, hs}, cursor_path: ctx.cursor_path, retry_ms: 0] ++
         opts}
    )
  end

  defp sync(pid), do: :sys.get_state(pid)

  defp fake(range) do
    {:ok, agent} = FakeDurableSource.start(records(range))
    agent
  end

  defp assert_handled(range), do: Enum.each(range, &assert_receive({:handled, ^&1}, 1000))

  test "replays records after the persisted cursor, then handles live ones in order", ctx do
    agent = fake(1..5)
    write_cursor(ctx, 2)
    pid = start(ctx, {FakeDurableSource, agent})
    assert_handled(3..5)
    FakeDurableSource.push_live(agent, 6)
    assert_handled([6])
    sync(pid)
    assert read_cursor(ctx) == 6
    refute_received {:handled, 1}
  end

  test "subscribes before replay so a record published during replay is not lost", ctx do
    agent = fake(1..5)
    FakeDurableSource.push_during_replay(agent, 6)
    pid = start(ctx, {FakeDurableSource, agent})
    assert_handled(1..6)
    sync(pid)
    refute_received {:handled, 6}
    assert read_cursor(ctx) == 6
  end

  test "crash between handle and cursor write redelivers (at-least-once)", ctx do
    agent = fake(1..5)
    start(ctx, {FakeDurableSource, agent}, %{kill_at: 3})
    assert_handled(1..3)
    # restarted by the supervisor: cursor is 2, so 3 is delivered again
    assert_handled(3..5)
  end

  test "duplicate live record is dropped", ctx do
    agent = fake(1..3)
    pid = start(ctx, {FakeDurableSource, agent})
    assert_handled(1..3)
    FakeDurableSource.push_live(agent, 4)
    FakeDurableSource.push_live(agent, 4)
    assert_handled([4])
    sync(pid)
    refute_received {:handled, 4}
  end

  test "live gap triggers catch-up instead of applying out of order", ctx do
    agent = fake(1..3)
    write_cursor(ctx, 3)
    pid = start(ctx, {FakeDurableSource, agent})
    sync(pid)
    # 4 and 5 exist in the source but were never announced live
    Agent.update(agent, &%{&1 | records: &1.records ++ records(4..5)})
    FakeDurableSource.push_live(agent, 6)
    assert_handled(4..6)
    sync(pid)
    refute_received {:handled, 6}
  end

  test "reset calls handle_reset and resumes from oldest", ctx do
    agent = fake(10..12)
    FakeDurableSource.reset_below(agent, 10)
    write_cursor(ctx, 2)
    start(ctx, {FakeDurableSource, agent})
    assert_receive {:reset, 10}, 1000
    assert_handled(10..12)
  end

  test "unavailable source reports once per outage and retries", ctx do
    agent = fake(1..2)
    FakeDurableSource.fail_next_replay(agent, 2)
    start(ctx, {FakeDurableSource, agent})
    assert_receive {:unavailable, :boom}, 1000
    assert_handled(1..2)
    refute_received {:unavailable, _}
  end

  test "handler error holds the cursor and retries the same record", ctx do
    agent = fake(1..3)
    pid = start(ctx, {FakeDurableSource, agent}, %{fail_at: 2})
    assert_handled([1, 2, 3])
    sync(pid)
    assert read_cursor(ctx) == 3
  end

  test "JournalSource reads the same records as the fake", ctx do
    path = Path.join(ctx.dir, "journal.jsonl")
    :ok = Journal.prepare(ctx.dir, path)
    for n <- 1..5, do: :ok = Journal.append(path, %{"seq" => n})
    write_cursor(ctx, 2)
    pid = start(ctx, {JournalSource, path})
    assert_handled(3..5)
    sync(pid)
    assert read_cursor(ctx) == 5
    assert JournalSource.replay(path, 9, 10) == {:reset, 1}
  end
end
