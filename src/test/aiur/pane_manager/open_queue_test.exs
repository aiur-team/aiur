defmodule Aiur.PaneManager.OpenQueueTest do
  use ExUnit.Case, async: true

  alias Aiur.PaneManager.OpenQueue

  test "queued? reports timer-map membership" do
    ref = make_ref()

    assert OpenQueue.queued?(%{"issue-1" => ref}, "issue-1")
    refute OpenQueue.queued?(%{"issue-1" => ref}, "issue-2")
  end

  test "enqueue appends fifo and records timer" do
    ref = make_ref()

    {queue, timers} = OpenQueue.enqueue(:queue.new(), %{}, "issue-1", :from, ref)

    assert :queue.to_list(queue) == [{"issue-1", :from, ref}]
    assert timers == %{"issue-1" => ref}
  end

  test "pop returns empty or first-in entry and rest" do
    ref1 = make_ref()
    ref2 = make_ref()

    queue =
      :queue.new()
      |> then(&:queue.in({"issue-1", :from1, ref1}, &1))
      |> then(&:queue.in({"issue-2", :from2, ref2}, &1))

    assert OpenQueue.pop(:queue.new()) == :empty
    assert {{"issue-1", :from1, ^ref1}, rest} = OpenQueue.pop(queue)
    assert :queue.to_list(rest) == [{"issue-2", :from2, ref2}]
  end

  test "pluck returns not_queued when identifier is absent from timers" do
    queue = :queue.in({"issue-1", :from, make_ref()}, :queue.new())

    assert OpenQueue.pluck(queue, %{}, "issue-1") == :not_queued
  end

  test "pluck returns not_queued without mutating timers when timer exists but queue entry is absent" do
    ref = make_ref()

    assert OpenQueue.pluck(:queue.new(), %{"issue-1" => ref}, "issue-1") == :not_queued
  end

  test "pluck removes a middle entry, keeps order, and deletes its timer" do
    ref1 = make_ref()
    ref2 = make_ref()
    ref3 = make_ref()

    queue =
      :queue.new()
      |> then(&:queue.in({"issue-1", :from1, ref1}, &1))
      |> then(&:queue.in({"issue-2", :from2, ref2}, &1))
      |> then(&:queue.in({"issue-3", :from3, ref3}, &1))

    timers = %{"issue-1" => ref1, "issue-2" => ref2, "issue-3" => ref3}

    assert {:from2, new_queue, new_timers} = OpenQueue.pluck(queue, timers, "issue-2")
    assert :queue.to_list(new_queue) == [{"issue-1", :from1, ref1}, {"issue-3", :from3, ref3}]
    assert new_timers == %{"issue-1" => ref1, "issue-3" => ref3}
  end

  test "timeout is 60 seconds" do
    assert OpenQueue.timeout_ms() == 60_000
  end
end
