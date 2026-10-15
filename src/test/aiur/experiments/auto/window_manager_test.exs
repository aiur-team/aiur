defmodule Aiur.Experiments.Auto.WindowManagerTest do
  use Aiur.TestSupport
  import ExUnit.CaptureIO
  alias Aiur.Config.Schema.Experiments.Auto, as: AutoConfig
  alias Aiur.Events.Exchange
  alias Aiur.{ExecutorBindings, ExecutorListener, ExecutorWakeInbox}
  alias Aiur.Experiments
  alias Aiur.Experiments.Auto.{Notifier, WindowManager}
  alias Aiur.Experiments.Store

  setup do
    root = Aiur.TestSupport.tmp_root!("experiment-windows")
    previous = Application.get_env(:aiur, :experiments_dir)
    Application.put_env(:aiur, :experiments_dir, root)
    start_supervised!(Store)
    start_supervised!({Notifier, path: Path.join(root, "latches.json")})

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :experiments_dir, previous), else: Application.delete_env(:aiur, :experiments_dir)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    %{root: root}
  end

  defp create(id \\ "exp-1", stop \\ "2026-01-15T00:00:00Z") do
    attrs = %{
      id: id,
      title: "Window experiment",
      min_samples: 1,
      design: %{kind: "before_after", change: %{type: "manual", ref: "fixture", time: "2026-01-01T00:00:00Z"}},
      metrics: [%{ref: "delivery-speed/start_to_merge"}],
      windows: %{before: %{start: "2025-12-18T00:00:00Z", end: "2026-01-01T00:00:00Z"}, after: %{start: "2026-01-01T00:00:00Z", end: stop}}
    }

    assert {:ok, spec} = Experiments.create(attrs, freeze: false)
    spec
  end

  defp manager(opts \\ []), do: start_supervised!({WindowManager, Keyword.merge([start_paused?: true, interval_ms: 3_600_000], opts)})

  defp evaluate(pid) do
    send(pid, :hourly)
    :sys.get_state(pid)
  end

  test "one-day manual experiment persists report_due and produces exactly one Executor wake across restart", %{root: root} do
    assert ExecutorBindings.allowlisted?("system.experiment.*.report_due")
    refute ExecutorBindings.allowlisted?("system.experiment.exp-1.internal")

    inbox =
      start_supervised!(
        {ExecutorWakeInbox, name: nil, path: Path.join(root, "wakes.ndjson"), cursor_path: Path.join(root, "cursor.json"), pending_path: Path.join(root, "pending.json"), debounce_ms: 60_000}
      )

    listener = start_supervised!({ExecutorListener, name: nil, inbox: inbox, resubscribe_interval_ms: :infinity})
    spec = create("exp-1.0", "2026-01-02T00:00:00Z")

    opts = [
      config: %AutoConfig{after_days: 1},
      clock: fn -> ~U[2026-01-02 00:00:00Z] end,
      samples: fn observed ->
        assert observed["id"] == spec.id
        assert observed["min_samples"] == 1
        [%{guard_met?: true, before_n: 1, after_n: 1, needed_n: 1}]
      end
    ]

    pid = manager(opts)
    evaluate(pid)
    assert {:ok, %{spec: %{"status" => "report_due", "report_reason" => "guard_met"} = due}} = Experiments.fetch(spec.id)
    schema = Path.expand("../../../../priv/experiments/spec.v1.schema.json", __DIR__) |> File.read!() |> Jason.decode!() |> ExJsonSchema.Schema.resolve()
    assert ExJsonSchema.Validator.validate(schema, due) == :ok
    output = capture_io(fn -> assert Aiur.ExperimentsCLI.run(verb: :list, argv: ["--status", "report_due", "--json"]) == 0 end)
    assert [%{"id" => "exp-1.0", "status" => "report_due"}] = Jason.decode!(output)
    stop_supervised!(WindowManager)
    stop_supervised!(Notifier)
    start_supervised!({Notifier, path: Path.join(root, "latches.json")})
    evaluate(manager(opts))
    :sys.get_state(listener)
    send(inbox, :flush)
    :sys.get_state(inbox)
    reports = ExecutorWakeInbox.pending(inbox) |> Enum.filter(&(&1["topic"] == "system.experiment.exp-1%2E0.report_due"))
    assert [%{"count" => 1, "ticket" => nil}] = reports
    assert Enum.count(Experiments.journal(spec.id), &(&1["kind"] == "report_due")) == 1
  end

  test "twenty merges share one ten-minute evaluation timer" do
    create()
    owner = self()

    pid =
      manager(
        samples: fn _ ->
          send(owner, :sampled)
          false
        end,
        clock: fn -> ~U[2026-01-02 00:00:00Z] end
      )

    Exchange.publish("ticket.1.pr.merged", %{topic: "ticket.1.pr.merged"})
    first = :sys.get_state(pid).merge_timer
    assert is_reference(first)
    assert Process.read_timer(first) <= 600_000
    for n <- 2..20, do: Exchange.publish("ticket.#{n}.pr.merged", %{topic: "ticket.#{n}.pr.merged"})
    assert :sys.get_state(pid).merge_timer == first
    refute_received :sampled
    send(pid, :merges)
    assert :sys.get_state(pid).merge_timer == nil
    assert_received :sampled
    refute_received :sampled
  end

  test "missing X4 extends the persisted window and still ends at the maximum" do
    spec = create()
    pid = manager(clock: fn -> ~U[2026-01-15 00:00:00Z] end)
    evaluate(pid)
    assert {:ok, %{spec: extended}} = Experiments.fetch(spec.id)
    assert extended["windows"]["after"]["end"] == "2026-01-22T00:00:00Z"
    assert extended["status"] == "active"
    stop_supervised!(WindowManager)
    evaluate(manager(clock: fn -> ~U[2026-02-12 00:00:00Z] end))
    assert {:ok, %{spec: due}} = Experiments.fetch(spec.id)
    assert due["status"] == "report_due"
    assert due["report_reason"] == "insufficient_data"
    assert due["windows"]["after"]["end"] == "2026-02-12T00:00:00Z"
  end

  test "facade truncation persists the reason and preserves terminal state" do
    spec = create()
    manager()
    assert {:ok, due} = Experiments.Auto.truncate(spec.id, ~U[2026-01-09 00:00:00Z], "rollback")
    assert due.status == "report_due"
    assert due.report_reason == "truncated"
    assert due.windows["after"]["end"] == "2026-01-09T00:00:00Z"
    assert :noop = Experiments.Auto.truncate(spec.id, ~U[2026-01-10 00:00:00Z], "newer_line")
    assert Enum.any?(Experiments.journal(spec.id), &(&1["kind"] == "report_due" and &1["reason"] == "rollback"))
  end
end
