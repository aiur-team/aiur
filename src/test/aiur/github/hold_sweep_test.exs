defmodule Aiur.GitHub.HoldSweepTest do
  use ExUnit.Case, async: true

  alias Aiur.GitHub.{HoldSweep, Quota}

  @now ~U[2026-10-16 11:18:42Z]

  setup do
    dir = Aiur.TestSupport.tmp_root!("aiur-hold-sweep")
    File.mkdir_p!(dir)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    parent = self()
    %{dir: dir, emit: fn name, opts -> send(parent, {:alert, name, opts}) end}
  end

  defp write_hold(dir, name, seconds_ahead), do: File.write!(Path.join(dir, name), "#{DateTime.to_unix(@now) + seconds_ahead}\n")

  # The field failure (#4698): a 30-day graphql-secondary-hold parked the fleet.
  test "removes and alerts on a hold more than an hour ahead, keeps plausible ones", %{dir: dir, emit: emit} do
    write_hold(dir, "graphql-secondary-hold", 30 * 86_400 + 60)
    write_hold(dir, "core-hold", 3_600)
    write_hold(dir, "core-secondary-hold", 60)
    File.write!(Path.join(dir, "agent-requests.tsv"), "#{DateTime.to_unix(@now) + 30 * 86_400}\n")

    assert %{"graphql-secondary-hold" => _} = HoldSweep.sweep(dir, @now, emit)

    refute File.exists?(Path.join(dir, "graphql-secondary-hold"))
    assert File.exists?(Path.join(dir, "core-hold"))
    assert File.exists?(Path.join(dir, "core-secondary-hold"))
    assert File.exists?(Path.join(dir, "agent-requests.tsv"))

    assert_receive {:alert, "system.github.quota.implausible_hold", opts}, 1_000
    assert opts[:needs_attention]
    assert opts[:message] =~ "graphql-secondary-hold"
    refute_receive {:alert, _name, _opts}, 50
  end

  # #4714: a fast-clock writer rewrote its bogus hold every minute; the sweep
  # removes it every time but raises one attention item, not one per minute.
  test "a hold rewritten every minute alerts once per hour", %{dir: dir, emit: emit} do
    alerted =
      Enum.reduce(0..59, %{}, fn minute, alerted ->
        write_hold(dir, "graphql-secondary-hold", 30 * 86_400)
        alerted = HoldSweep.sweep(dir, DateTime.add(@now, minute * 60), emit, alerted)
        refute File.exists?(Path.join(dir, "graphql-secondary-hold"))
        alerted
      end)

    assert_receive {:alert, "system.github.quota.implausible_hold", _opts}, 1_000
    refute_receive {:alert, _name, _opts}, 50

    # A different hold file is a different writer's news, and the hour reopens the window.
    write_hold(dir, "core-hold", 30 * 86_400)
    alerted = HoldSweep.sweep(dir, @now, emit, alerted)
    assert_receive {:alert, "system.github.quota.implausible_hold", opts}, 1_000
    assert opts[:message] =~ "core-hold"

    write_hold(dir, "graphql-secondary-hold", 30 * 86_400)
    HoldSweep.sweep(dir, DateTime.add(@now, 3_600), emit, alerted)
    assert_receive {:alert, "system.github.quota.implausible_hold", opts}, 1_000
    assert opts[:message] =~ "graphql-secondary-hold"
  end

  test "the quota server alerts once across polls that keep rewriting a hold", %{dir: dir, emit: emit} do
    parent = self()

    refresh_fun = fn ->
      write_hold(dir, "graphql-secondary-hold", 30 * 86_400)
      send(parent, :refreshed)
    end

    start_supervised!({Quota, name: nil, clock: fn -> @now end, hold_dir: dir, request_log_path: nil, emit_fun: emit, refresh_fun: refresh_fun, refresh?: true, refresh_interval_ms: 5})

    # Each poll's sweep runs after its `:refreshed`; the fifth guarantees four completed sweeps.
    for _poll <- 1..5, do: assert_receive(:refreshed, 1_000)
    assert_receive {:alert, "system.github.quota.implausible_hold", _opts}, 1_000
    refute_receive {:alert, _name, _opts}, 50
  end

  test "a nil hold dir is a no-op", %{emit: emit} do
    assert HoldSweep.sweep(nil, @now, emit) == %{}
  end

  test "the quota server sweeps on startup and after each refresh poll", %{dir: dir, emit: emit} do
    write_hold(dir, "core-secondary-hold", 30 * 86_400)

    start_supervised!({Quota, name: nil, clock: fn -> @now end, hold_dir: dir, request_log_path: nil, emit_fun: emit, refresh?: false})

    refute File.exists?(Path.join(dir, "core-secondary-hold"))
    assert_receive {:alert, "system.github.quota.implausible_hold", _opts}, 1_000

    # The refresh poll itself writes the bogus hold; the sweep after it must remove it.
    start_supervised!(
      {Quota,
       name: nil,
       clock: fn -> @now end,
       hold_dir: dir,
       request_log_path: nil,
       emit_fun: emit,
       refresh_fun: fn -> write_hold(dir, "graphql-secondary-hold", 30 * 86_400) end,
       refresh?: true,
       refresh_interval_ms: 60_000},
      id: :polling
    )

    assert_receive {:alert, "system.github.quota.implausible_hold", opts}, 2_000
    assert opts[:message] =~ "graphql-secondary-hold"
    refute File.exists?(Path.join(dir, "graphql-secondary-hold"))
  end
end
