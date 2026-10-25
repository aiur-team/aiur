defmodule Aiur.ExecutorSweep.TriageBacklogTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Aiur.ExecutorAttention.CLI
  alias Aiur.ExecutorSweep
  alias Aiur.ExecutorSweep.{Checks, TriageBacklog}
  alias Aiur.OpenTicketSource.Snapshot

  @now ~U[2026-10-16 12:00:00Z]

  defp ticket(id, labels, created_at), do: %{identifier: id, labels: labels, created_at: created_at}

  defp line(fields), do: TriageBacklog.status_line(struct(Snapshot, fields), @now)

  test "status counts only needs-triage tickets older than an hour and names the oldest" do
    tickets = [
      ticket("4466", ["needs-triage"], ~U[2026-10-15 09:00:00Z]),
      ticket("4500", ["needs-triage", "bug"], ~U[2026-10-16 10:30:00Z]),
      ticket("4510", ["needs-triage"], ~U[2026-10-16 11:30:00Z]),
      ticket("4511", ["agent:todo"], ~U[2026-10-15 09:00:00Z])
    ]

    assert line(status: :available, tickets: tickets) == "TRIAGE needs-triage >1h 2 (oldest #4466 27h)"
  end

  test "status names each projection state on its own" do
    assert line(status: :available) == "TRIAGE needs-triage >1h 0"
    assert line(status: :stale, observed_at: ~U[2026-10-16 11:46:00Z]) == "TRIAGE needs-triage >1h 0 STALE observed 14m ago"
    assert line(status: :stale) == "TRIAGE needs-triage >1h 0 STALE observed age unknown"
    assert line(status: :unavailable) == "TRIAGE unavailable (the open-ticket listing is not loaded)"
    assert line(status: :unsupported) == "TRIAGE unsupported (tracker has no open-ticket listing)"
  end

  test "a truncated listing is a lower bound and unknown ages are counted" do
    tickets = [ticket("1", ["needs-triage"], ~U[2026-10-16 09:00:00Z]), ticket("2", ["needs-triage"], nil)]

    assert line(status: :available, truncated?: true, tickets: tickets) == "TRIAGE needs-triage >1h >=1 (oldest #1 3h) unknown age 1 TRUNCATED"
  end

  test "aiur status prints the TRIAGE line from the open-ticket projection" do
    snapshot = %Snapshot{status: :available, tickets: [ticket("7", ["needs-triage"], ~U[2026-10-15 09:00:00Z])]}
    parent = self()
    previous = Process.whereis(Aiur.OpenTicketSource)
    if previous, do: Process.unregister(Aiur.OpenTicketSource)

    stub =
      spawn(fn ->
        Process.register(self(), Aiur.OpenTicketSource)
        send(parent, :stub_ready)

        receive do
          {:"$gen_call", from, :snapshot} -> GenServer.reply(from, snapshot)
        end
      end)

    on_exit(fn ->
      Process.exit(stub, :kill)
      if previous && Process.alive?(previous), do: Process.register(previous, Aiur.OpenTicketSource)
    end)

    assert_receive :stub_ready, 1_000
    assert capture_io(&CLI.print_wake_status/0) =~ ~r/TRIAGE needs-triage >1h 1 \(oldest #7 \d+h\)/
  end

  test "a closed ticket still labelled needs-triage produces no finding" do
    # The open-ticket projection lists open issues only; the cached label set also holds closed ones.
    snapshot = %{tickets: [%{number: 1277, labels: ["needs-triage"], created_at: ~U[2026-10-01 09:00:00Z]}], open_tickets: %Snapshot{status: :available}}

    refute Enum.any?(Checks.all(snapshot, @now), &(&1.kind == "stale_needs_triage"))
  end

  test "no finding while the projection is not available" do
    open = [ticket("1", ["needs-triage"], ~U[2026-10-16 09:00:00Z])]

    for status <- [:stale, :unavailable, :unsupported] do
      assert [] = Checks.all(%{open_tickets: %Snapshot{status: status, tickets: open}}, @now)
    end
  end

  # Mirrors the daemon: until the projection is available `tickets` is nil, so ticket hygiene reports its source unavailable.
  defp start_sweep(state, publish_fun, seen_path) do
    sweep = fn ->
      {status, tickets} = Agent.get(state, & &1)
      snapshot = %{open_tickets: %Snapshot{status: status, tickets: tickets}, tickets: if(status == :available, do: [], else: nil)}
      snapshot |> Checks.all(@now) |> Enum.filter(&(&1.kind in ["stale_needs_triage", "sweep_source_unavailable"]))
    end

    {:ok, pid} = ExecutorSweep.start_link(name: nil, seen_path: seen_path, interval_ms: 60_000, sweep_fun: sweep, publish_fun: publish_fun)
    :sys.get_state(pid)
    {:ok, pid}
  end

  defp sweep_once(pid), do: send(pid, :sweep) && :sys.get_state(pid)

  defp seen_path do
    root = Aiur.TestSupport.tmp_root!("aiur-triage-seen")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    File.mkdir_p!(root)
    Path.join(root, "seen.json")
  end

  test "after restart, a changed stale triage backlog wakes once with its count and oldest ticket" do
    parent = self()
    path = seen_path()
    {:ok, state} = Agent.start_link(fn -> {:available, [ticket("1", ["needs-triage"], ~U[2026-10-16 09:00:00Z])]} end)

    assert {:ok, pid} = start_sweep(state, &send(parent, {:finding, &1}), path)
    GenServer.stop(pid)
    assert File.exists?(path)

    Agent.update(state, fn {status, tickets} -> {status, [ticket("2", ["needs-triage"], ~U[2026-10-16 10:00:00Z]) | tickets]} end)
    assert {:ok, pid} = start_sweep(state, &send(parent, {:finding, &1}), path)
    assert_receive {:finding, %{kind: "stale_needs_triage", ticket: 1, oldest_ticket: 1, ticket_count: 2}}, 1_000

    GenServer.stop(pid)
    Agent.stop(state)
  end

  test "an unavailable-then-available projection cycle with an unchanged backlog wakes nothing" do
    parent = self()
    open = [ticket("1", ["needs-triage"], ~U[2026-10-16 09:00:00Z])]
    {:ok, state} = Agent.start_link(fn -> {:unavailable, []} end)

    assert {:ok, pid} = start_sweep(state, &send(parent, {:finding, &1}), seen_path())

    for status <- [:available, :stale, :unavailable, :available] do
      Agent.update(state, fn _ -> {status, open} end)
      sweep_once(pid)
    end

    refute_receive {:finding, %{kind: "stale_needs_triage"}}, 50

    GenServer.stop(pid)
    Agent.stop(state)
  end

  test "a triage wake lands on the ticket's own topic" do
    root = Aiur.TestSupport.tmp_root!("aiur-triage-wake")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)

    inbox_opts = [name: nil, debounce_ms: 0, path: Path.join(root, "wakes.ndjson"), cursor_path: Path.join(root, "cursor.json"), pending_path: Path.join(root, "pending.json")]
    assert {:ok, inbox} = Aiur.ExecutorWakeInbox.start_link(inbox_opts)
    {:ok, state} = Agent.start_link(fn -> {:available, []} end)
    assert {:ok, pid} = start_sweep(state, &ExecutorSweep.Wake.publish(&1, inbox), seen_path())

    Agent.update(state, fn _ -> {:available, [ticket("4466", ["needs-triage"], ~U[2026-10-16 09:00:00Z])]} end)
    sweep_once(pid)

    assert {:ok, [%{"topic" => "ticket.4466.agent.executor-sweep.finding", "ticket" => 4466, "oldest_ticket" => 4466, "ticket_count" => 1, "kind" => "stale_needs_triage"}]} =
             Aiur.ExecutorWakeInbox.wait(1_000, inbox)

    GenServer.stop(pid)
    GenServer.stop(inbox)
    Agent.stop(state)
  end
end
