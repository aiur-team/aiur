defmodule Aiur.AgentRunner.AdoptedConcurrencyTest do
  use Aiur.TestSupport

  alias Aiur.AgentRunner.Handoff
  alias Aiur.{ProcessReaper, Tmux}
  alias Aiur.RunTelemetry.Dataset.Resources
  alias Aiur.RunTelemetry.Sampler
  alias AiurWeb.OperatorControlCenter.Analytics.Presenter

  @tickets ["4629", "4730", "4621"]

  setup do
    previous = Application.get_env(:aiur, :process_reaper_registrations)
    Application.put_env(:aiur, :process_reaper_registrations, true)
    original_reaper = Process.whereis(ProcessReaper)
    if original_reaper, do: Process.unregister(ProcessReaper)
    reaper = start_supervised!(ProcessReaper)
    # Adoption renames each pane through the daemon's Tmux; stand a mock in its place.
    original_tmux = Process.whereis(Tmux)
    if original_tmux, do: Process.unregister(Tmux)
    tmux = start_supervised!({Tmux, [transport: {:mock, self()}, name: Tmux, session: "test"]})

    on_exit(fn ->
      if Process.alive?(reaper), do: GenServer.stop(reaper)
      if original_reaper && Process.alive?(original_reaper), do: Process.register(original_reaper, ProcessReaper)
      if original_tmux && Process.alive?(original_tmux), do: Process.register(original_tmux, Tmux)
      Application.put_env(:aiur, :process_reaper_registrations, previous)
    end)

    %{tmux: tmux}
  end

  # Regression guard for #4840 adopted-root attribution; it passes with this ticket's three lib changes reverted.
  test "agents adopted at restart count in the concurrency sample", %{tmux: tmux} do
    @tickets |> Enum.with_index(100) |> Enum.each(fn {ticket, pid} -> adopt!(tmux, ticket, pid) end)

    first = sample(%{}, 1_000, 0)
    second = sample(first.previous, 6_000, 50)
    model = Presenter.model(reduce(dataset(first.records, 1_000) ++ dataset(second.records, 6_000)), cap: 10, cores: 4, buckets: 1)

    assert [%{conc: 3}] = model.series
    assert model.kpis.conc_now == 3
  end

  defp adopt!(tmux, ticket, os_pid) do
    session = %{backend: "claude-repl", pane_id: "%#{os_pid}", os_pid: os_pid, identifier: ticket}

    record = %{
      "backend" => "claude-repl",
      "transport" => %{"kind" => "repl", "socket" => "aiur-test"},
      "session_state" => Handoff.encode(session),
      "turn_context" => Handoff.encode(%{issue: %Aiur.Issue{id: ticket, identifier: ticket}}),
      "queued_frames" => Handoff.encode([])
    }

    # The first decode loads every app module; keep that out of the mock's reply window.
    Handoff.decode(record["queued_frames"])
    attach = Task.async(fn -> Handoff.attach(record, 2) end)
    assert {:ok, _session} = answer_tmux(tmux, attach)
  end

  # Daemon pid 1 with each adopted claude root as its own tree; cpu ticks advance by `ticks`.
  defp sample(previous, now_ms, ticks) do
    table = Map.new([1, 100, 101, 102], &{&1, %{pid: &1, ppid: 0, cpu_ticks: &1 + ticks, start_time_ticks: &1}})
    measured = Map.new(table, fn {pid, process} -> {pid, Map.merge(process, %{rss_bytes: 1_000, fd_count: 1, read_bytes: 0, write_bytes: 0})} end)

    Sampler.sample_once(previous,
      process_table_fun: fn -> {:ok, table, []} end,
      measure_fun: fn _table, pids -> {:ok, Map.take(measured, MapSet.to_list(pids)), []} end,
      fleet_snapshot_fun: fn -> {:current, %{capacity: %{occupied: 3, configured: 10, max: 10, effective: 10}}, %{age_ms: 0}} end,
      build_status_fun: fn -> :unavailable end,
      fd_headroom_fun: fn -> :unavailable end,
      daemon_pid: 1,
      operator_pid: nil,
      monotonic_ms: now_ms,
      clock_ticks_per_second: 100
    )
  end

  # Shape sampler output the way the telemetry writer persists it.
  defp dataset(records, ts) do
    Enum.map(records, fn record ->
      %{kind: "resource", attributes: record |> Jason.encode!() |> Jason.decode!(), timestamp_ms: ts, timestamp_iso: nil, boot_id: "b", record_id: "#{record.actor}:#{ts}"}
    end)
  end

  defp reduce(records) do
    {actors, _warnings} = Resources.reduce_actors(records, [])
    %{actors: actors, tickets: %{}, provenance: %{}}
  end

  # Answer every command the mock sees (daemon processes may share it) until the task returns.
  defp answer_tmux(tmux, task) do
    receive do
      {:tmux_mock_out, _command} ->
        send(tmux, {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})
        answer_tmux(tmux, task)

      {ref, result} when ref == task.ref ->
        Process.demonitor(ref, [:flush])
        result
    after
      10_000 -> flunk("Handoff.attach never returned")
    end
  end
end
