Code.require_file("../../support/build_home/queue_read_model_fixture.ex", __DIR__)

defmodule AiurWeb.Build.PlannedRowsReadTest do
  use ExUnit.Case, async: true
  alias AiurWeb.Build.PlannedRows
  import Aiur.Test.BuildHome.QueueReadModelFixture

  defmodule Queue do
    def show, do: Process.get(:planned_queue)
  end

  defmodule History do
    def snapshot(_opts) do
      send(self(), :snapshot_called)
      raise "whole-store snapshot forbidden"
    end

    def rows(numbers, []) do
      send(self(), {:history_rows, numbers})

      rows =
        Enum.flat_map(numbers, fn number ->
          case Process.get(:planned_history)[number] do
            nil -> []
            row -> [row]
          end
        end)

      send(self(), {:history_returned, length(rows)})
      {:ok, rows, %{state: :healthy}}
    end
  end

  defmodule UnavailableHistory do
    def rows(_numbers, []), do: {:error, :unavailable}
    def snapshot(opts), do: History.snapshot(opts)
  end

  test "unavailable History preserves queue rows and caller todo rows" do
    Process.put(:planned_queue, show([item(1)]))
    result = PlannedRows.read(queue: Queue, history: UnavailableHistory, todo_rows: [history_row(3)], todo_label: "agent:todo")
    assert Enum.map(result.rows, &{&1.num, &1.qpos}) == [{1, 1}, {3, nil}]
    assert result.source.state == "ok"
    refute_received :snapshot_called
  end

  test "read copies only planned queue rows regardless of unrelated History size" do
    Process.put(:planned_queue, show([item(20), item(10), item(20), item(30, state: :claimed), item(40, state: :completed)]))

    for size <- [100, 10_000] do
      Process.put(:planned_history, Map.new(1..size, &{&1, history_row(&1)}))
      result = PlannedRows.read(queue: Queue, history: History)
      assert Enum.map(result.rows, & &1.num) == [20, 10]
      assert_received {:history_rows, [20, 10]}
      assert_received {:history_returned, 2}
      refute_received :snapshot_called
      refute_received {:history_rows, _numbers}
    end
  end

  test "caller todo rows keep lifecycle, queue membership, active and label exclusions" do
    Process.put(:planned_queue, show([item(1), item(2, state: :claimed)]))
    Process.put(:planned_history, %{1 => history_row(1, :closed)})
    candidates = [history_row(1), history_row(2), history_row(3), history_row(4), history_row(5, :closed), history_row(6, :open, [])]

    result = PlannedRows.read(queue: Queue, history: History, todo_rows: candidates, todo_label: "agent:todo", active: MapSet.new([4]))
    assert [%{num: 3, ord: 0, qpos: nil}] = result.rows
    assert_received {:history_rows, [1]}
    assert_received {:history_returned, 1}
    refute_received :snapshot_called

    assert [] == PlannedRows.read(queue: Queue, history: History, todo_rows: candidates).rows
  end

  test "empty or unavailable queue does not read History and can use caller todo rows" do
    for input <- [show([]), show([item(1)], status: :store_unavailable)] do
      Process.put(:planned_queue, input)
      assert [%{num: 3, qpos: nil}] = PlannedRows.read(queue: Queue, history: History, todo_rows: [history_row(3)], todo_label: "agent:todo").rows
      refute_received {:history_rows, _numbers}
      refute_received :snapshot_called
    end
  end

  defp history_row(number, state \\ :open, labels \\ ["agent:todo"]),
    do: %{number: number, lifecycle: %{state: state}, labels: labels, created_at: ~U[2026-10-08 00:00:00Z], title: String.duplicate("history ", 128)}
end
