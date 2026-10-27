defmodule Aiur.Events.Export.BacklogTest do
  use ExUnit.Case, async: false
  alias Aiur.Application.ExportChildren
  alias Aiur.Events.{Catalog, Export}
  alias Aiur.Events.Export.Exporter

  defmodule SignalSink do
    def emit_system(topic, opts) do
      send(self(), {:signal, topic, opts})
      :ok
    end
  end

  setup do
    owner = self()
    root = Path.join(System.tmp_dir!(), "export-backlog-#{System.unique_integer([:positive])}")
    previous = :persistent_term.get({Export, :status}, :absent)

    on_exit(fn ->
      if previous == :absent, do: :persistent_term.erase({Export, :status}), else: :persistent_term.put({Export, :status}, previous)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    opts = [
      name: nil,
      identity: fn -> {:ok, "backlog/instance"} end,
      directory: fn -> {:ok, root} end,
      subscribe: fn _ -> :ok end,
      backlog_threshold: 5,
      backlog_check_interval: 60_000,
      on_backlog: fn action, stats -> send(owner, {action, stats}) end
    ]

    {:ok, opts: opts}
  end

  test "raises once when the actual mailbox stays above threshold for two checks", ctx do
    pid = start_supervised!({Exporter, ctx.opts})
    assert :sys.get_state(pid).state == :available
    backlog(pid, 1)
    refute_received {:raised, _}
    backlog(pid, 4)
    assert_received {:raised, %{len: len, threshold: 5}}
    assert len >= 20
    refute_received {:raised, _}
    refute_received {:cleared, _}
  end

  test "does not raise on a single spike or accumulate nonconsecutive spikes", ctx do
    pid = start_supervised!({Exporter, ctx.opts})
    :sys.get_state(pid)
    backlog(pid, 1)
    tick(pid)
    backlog(pid, 1)
    refute_received {:raised, _}
  end

  test "clears once below half the threshold for two checks and can raise again", ctx do
    pid = start_supervised!({Exporter, ctx.opts})
    :sys.get_state(pid)
    backlog(pid, 2)
    assert_received {:raised, _}
    backlog(pid, 2, 3)
    refute_received {:cleared, _}
    tick(pid)
    refute_received {:cleared, _}
    backlog(pid, 1)
    tick(pid)
    refute_received {:cleared, _}
    tick(pid)
    assert_received {:cleared, %{len: len, threshold: 5}}
    assert len * 2 < 5
    tick(pid)
    refute_received {:cleared, _}
    backlog(pid, 2)
    assert_received {:raised, _}
    refute_received {:raised, _}
  end

  test "future regression guard: unavailable exporter drains and counts events without a backlog attention", ctx do
    pid = start_supervised!({Exporter, Keyword.put(ctx.opts, :identity, fn -> {:error, :identity_unavailable} end)})
    assert :sys.get_state(pid).state == :unavailable
    backlog(pid, 4)
    assert :sys.get_state(pid).dropped == 20
    refute_received {:raised, _}
    refute_received {:cleared, _}
  end

  test "schedules a five-second check by default and replaces the timer after a tick", ctx do
    pid = start_supervised!({Exporter, Keyword.delete(ctx.opts, :backlog_check_interval)})
    first = :sys.get_state(pid).backlog_timer
    assert Process.read_timer(first) in 0..5_000
    tick(pid)
    second = :sys.get_state(pid).backlog_timer
    assert second != first
    assert Process.read_timer(first) == false
    assert Process.read_timer(second) in 0..5_000
  end

  test "both backlog signals are ledgered and excluded from export" do
    for topic <- ["system.events.export_backlog", "system.events.export_backlog.resolved"] do
      entry = Catalog.lookup(topic)
      assert entry.class == :ledgered
      assert entry.owner == "event-bus"
      refute entry.export?
    end
  end

  test "composition root maps backlog transitions to the signal port" do
    previous = Application.fetch_env(:aiur, :signal)
    Application.put_env(:aiur, :signal, alert_sink: SignalSink)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:aiur, :signal, value)
        :error -> Application.delete_env(:aiur, :signal)
      end
    end)

    [{Exporter, callbacks}] = ExportChildren.child_specs(true)
    callbacks[:on_backlog].(:raised, %{len: 20, threshold: 5})
    assert_received {:signal, "system.events.export_backlog", raised}
    assert raised[:needs_attention] == true
    assert raised[:severity] == "warning"
    assert raised[:reason] =~ "20 exceeds 5"
    callbacks[:on_backlog].(:cleared, %{len: 0, threshold: 5})
    assert_received {:signal, "system.events.export_backlog.resolved", cleared}
    assert cleared[:needs_attention] == false
    assert cleared[:severity] == "info"
    assert cleared[:reason] =~ "0 below half of 5"
  end

  defp tick(pid) do
    send(pid, :check_backlog)
    :sys.get_state(pid)
  end

  defp backlog(pid, checks, messages \\ 20) do
    :sys.suspend(pid)

    try do
      for _ <- 1..checks, do: send(pid, :check_backlog)
      # Unexported messages occupy the real mailbox without disk writes.
      for _ <- 1..messages, do: send(pid, {:event, %{topic: "executor.private"}})
    after
      :sys.resume(pid)
    end

    :sys.get_state(pid)
  end
end
