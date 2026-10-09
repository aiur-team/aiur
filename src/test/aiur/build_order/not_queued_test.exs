defmodule Aiur.BuildOrder.NotQueuedTest do
  use ExUnit.Case, async: true
  alias Aiur.BuildOrder.NotQueued
  alias Aiur.OpenTicketSource.Snapshot
  @time ~U[2026-10-08 10:00:00Z]

  test "an unlabelled open ticket is not queued" do
    assert %{state: :ok, reasons: [], skipped: 0, observed_at: @time, rows: [row]} = build([ticket(31)])
    assert row == %{num: 31, title: "Ticket 31", cx: nil, pts: nil, created: @time, ord: 31, sec: "nq", status: "open"}
  end

  test "agent:todo outside a queue is planned, not here" do
    assert build([ticket(10, ["agent:todo"])]).rows == []
  end

  test "every active state label excludes" do
    tickets = for {suffix, num} <- Enum.with_index(~w(in-progress ci-wait human-review rework merging error), 1), do: ticket(num, ["agent:#{suffix}"])
    assert build(tickets).rows == []
    assert build([ticket(20, ["bot:in-progress"])], queue(), label_prefix: "Bot").rows == []
  end

  test "terminal labels and markers do not exclude" do
    labels = ~w(agent:done agent:cancelled agent:canceled agent:paused agent:parked agent:watch agent:rate-limit-fallback human:todo needs-triage)
    tickets = for {label, num} <- Enum.with_index(labels, 1), do: ticket(num, [label])
    assert Enum.map(build(tickets).rows, & &1.num) == Enum.to_list(1..9)
    assert [%{num: 20}] = build([ticket(20, ["bot:done"])], queue(), label_prefix: "Bot").rows
  end

  test "queue items are excluded, removed and closed items are not" do
    items = for {state, num} <- Enum.with_index([:waiting, :held, :unknown, :removed, :completed, :cancelled], 5), do: %{number: num, state: state}
    queue = %{queue() | queues: [%{items: Enum.take(items, 2)}, %{items: Enum.drop(items, 2)}]}
    assert Enum.map(build(Enum.map(5..10, &ticket/1), queue).rows, & &1.num) == [8, 9, 10]
  end

  test "the now band wins" do
    assert build([ticket(40)], queue(), active: MapSet.new([40])).rows == []
  end

  test "design order is issue number ascending rather than creation time" do
    tickets = for num <- [575, 577, 576], do: %{ticket(num) | created_at: DateTime.add(@time, -num)}
    rows = build(tickets).rows
    assert Enum.map(rows, & &1.num) == [575, 576, 577]
    assert Enum.map(rows, & &1.ord) == [575, 576, 577]
  end

  test "several hundred rows have no cap" do
    rows = build(Enum.map(600..1//-1, &ticket/1)).rows
    assert length(rows) == 600
    assert hd(rows).num == 1
    assert List.last(rows).num == 600
  end

  test "empty is ok, not unavailable" do
    assert %{state: :ok, reasons: [], rows: []} = build([])
  end

  test "unknown complexity is nil, not a number" do
    tickets = [ticket(1), ticket(2, ["complexity:9"]), ticket(3, ["complexity:2", "complexity:3"]), ticket(4, ["complexity:4"])]
    assert Enum.map(build(tickets).rows, &{&1.cx, &1.pts}) == [{nil, nil}, {nil, nil}, {nil, nil}, {4, 5}]
    assert Enum.map([:unknown, nil, 0, 6, "1", 1.0], &NotQueued.points/1) == [nil, nil, nil, nil, nil, nil]
  end

  test "points table" do
    assert Enum.map(1..5, &NotQueued.points/1) == [1, 2, 3, 5, 8]
  end

  test "open source unavailable gives no rows" do
    assert %{state: :unavailable, reasons: [:open_tickets_unavailable], rows: []} = NotQueued.build(%Snapshot{tickets: [ticket(31)]}, queue())
  end

  test "queue store unavailable gives no rows" do
    assert %{state: :unavailable, reasons: [:queue_unavailable], observed_at: nil, rows: []} = build([ticket(31)], %{status: :store_unavailable})
  end

  test "disabled or unsupported queues have no membership" do
    for {status, reason} <- [disabled: :queue_disabled, unsupported_tracker: :queue_unsupported] do
      assert %{state: :ok, reasons: [^reason], observed_at: @time, rows: [%{num: 31}]} =
               build([ticket(31)], %{status: status, queues: [%{items: [%{number: 31, state: :waiting}]}]})
    end
  end

  test "unknown queue shape and failed reads have distinct reasons" do
    for queue <- [:error, %{}, %{status: :paused}, %{"status" => "running"}, nil] do
      assert %{state: :unavailable, reasons: [:queue_status_unknown], observed_at: nil, rows: []} = build([ticket(31)], queue)
    end

    assert %{state: :unavailable, reasons: [:queue_read_failed], observed_at: nil, rows: []} = build([ticket(31)], {:error, :timeout})
  end

  test "stale reasons accumulate and observation is the oldest across every source" do
    oldest = ~U[2026-10-08 09:58:00Z]
    queue = %{queue() | sources: %{"tracker_observation" => %{freshness: :current, observed_at: DateTime.add(@time, 60)}, "build_order:2573" => %{freshness: :stale, observed_at: oldest}}}
    queue = Map.put(queue, :snapshot, %{captured_at: DateTime.add(@time, 300)})
    snapshot = %Snapshot{status: :stale, tickets: [ticket(31)], observed_at: @time}
    assert %{state: :stale, reasons: [:open_tickets_stale, :queue_stale], observed_at: ^oldest, rows: [%{num: 31}]} = NotQueued.build(snapshot, queue)
  end

  test "missing freshness is not current and missing observation is unknown" do
    for sources <- [%{}, %{"tracker_observation" => %{freshness: :unknown, observed_at: nil}}, %{"tracker_observation" => %{observed_at: nil}}] do
      assert %{state: :stale, reasons: [:queue_freshness_unknown], observed_at: nil, rows: [%{num: 31}]} = build([ticket(31)], %{queue() | sources: sources})
    end

    assert %{state: :stale, reasons: [:queue_freshness_unknown], observed_at: nil} = build([], Map.delete(queue(), :sources))
    assert build([], %{queue() | sources: %{tracker: %{freshness: :current, observed_at: nil}}}).observed_at == nil
    assert NotQueued.build(%Snapshot{status: :available, observed_at: nil}, queue()).observed_at == nil
  end

  test "unsupported tracker wins while preserving other failure causes" do
    snapshot = %Snapshot{status: :unsupported, tickets: [ticket(31)]}
    assert %{state: :unsupported, reasons: [:tracker_unsupported], rows: []} = NotQueued.build(snapshot, queue())
    assert %{state: :unsupported, reasons: [:tracker_unsupported, :queue_unavailable], rows: []} = NotQueued.build(snapshot, %{status: :store_unavailable})
    assert %{state: :unavailable, reasons: [:open_tickets_stale, :queue_read_failed], rows: []} = NotQueued.build(%{snapshot | status: :stale}, {:error, :timeout})
  end

  test "truncation passes through" do
    assert NotQueued.build(%Snapshot{status: :available, truncated?: true}, queue()).truncated?
  end

  test "malformed tickets are counted before membership filtering" do
    tickets = [%{ticket(1) | identifier: "abc"}, ticket(0), %{ticket(3) | title: nil}, %{ticket(4) | identifier: "4tail"}, %{ticket(5) | identifier: nil}]
    assert %{skipped: 5, rows: []} = build(tickets)
  end

  test "writes paused still respects membership and source freshness" do
    queue = %{queue() | status: :writes_paused, queues: [%{items: [%{number: 31, state: :waiting}]}]}
    assert %{state: :ok, rows: []} = build([ticket(31)], queue)
    queue = %{queue | sources: %{tracker: %{freshness: :stale, observed_at: @time}}}
    assert %{state: :stale, reasons: [:queue_stale], rows: [%{num: 32}]} = build([ticket(32)], queue)
  end

  test "design dataset parity" do
    for {dataset, count} <- [{"live", 22}, {"newrepo", 6}] do
      data = __DIR__ |> Path.join("../../fixtures/build_home/#{dataset}.json") |> File.read!() |> Jason.decode!() |> Map.fetch!("data")
      tickets = Enum.map(data["nq"] ++ data["plan"] ++ data["now"], &ticket(&1["num"], ["complexity:#{&1["cx"]}"]))
      items = Enum.map(data["plan"], &%{number: &1["num"], state: :waiting})
      rows = build(tickets, %{queue() | queues: [%{items: items}]}, active: MapSet.new(data["now"], & &1["num"])).rows
      assert length(rows) == count
      assert Enum.map(rows, &{&1.num, &1.cx, &1.pts}) == Enum.map(data["nq"], &{&1["num"], &1["cx"], &1["pts"]})
    end
  end

  defp ticket(num, labels \\ []), do: %{identifier: to_string(num), title: "Ticket #{num}", labels: labels, created_at: @time}
  defp queue, do: %{status: :running, queues: [], sources: %{"tracker_observation" => %{freshness: :current, observed_at: @time}}}
  defp build(tickets, queue \\ queue(), opts \\ []), do: NotQueued.build(%Snapshot{status: :available, tickets: tickets, observed_at: @time}, queue, opts)
end
