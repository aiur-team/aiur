defmodule Aiur.Experiments.AnalystReconciliationTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Aiur.Events.Exchange
  alias Aiur.Experiments
  alias Aiur.Experiments.{AnalystTrigger, Snapshot, Store}

  setup do
    root = Aiur.TestSupport.tmp_root!("analyst-reconcile")
    previous = Application.get_env(:aiur, :experiments_dir)
    Application.put_env(:aiur, :experiments_dir, root)
    :ok = Aiur.TestSupport.ensure_pubsub_running()
    unless Process.whereis(Exchange), do: start_supervised!(Exchange)
    start_supervised!(Store)

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :experiments_dir, previous), else: Application.delete_env(:aiur, :experiments_dir)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    :ok
  end

  defp create(extra \\ %{}) do
    attrs = %{
      title: "Recovery",
      min_samples: 1,
      design: %{kind: "before_after", change: %{type: "manual", ref: "test", time: "2026-10-09T00:00:00Z"}},
      metrics: [%{ref: "delivery-speed/start_to_merge"}]
    }

    {:ok, spec} = Experiments.create(Map.merge(attrs, extra), freeze: false)
    spec
  end

  defp trigger(request \\ nil) do
    parent = self()
    request = request || fn id, opts -> send(parent, {:requested, id, opts}) end
    start_supervised!({AnalystTrigger, start_paused?: true, enabled: fn -> true end, request: request})
  end

  defp reconcile(pid) do
    send(pid, :reconcile)
    :sys.get_state(pid)
  end

  defp freeze(id, window, groups \\ [nil]) do
    context = %{
      evaluate: fn refs, range, _ ->
        rows = Enum.map(groups, fn group -> %{"unit_id" => "#{window}-#{group}", "at" => range["start"], "value" => 1, "censored" => false, "attrs" => %{"backend" => group}} end)
        Map.new(refs, &{&1, %{"coverage" => %{"state" => "captured"}, "observations" => rows}})
      end
    }

    assert {:ok, _snapshot} = Snapshot.freeze(id, window, context: context)
  end

  test "reconciliation recovers a missed feature preregistration while it is still an armed draft" do
    design = %{kind: "before_after", change: %{type: "epic_merge", ref: "feature", time: "2026-10-09T00:00:00Z", evidence: %{source: "feature", armed: true}}}
    spec = create(%{status: "draft", design: design})
    pid = trigger()
    reconcile(pid)
    assert_received {:requested, id, opts}
    assert id == spec.id
    assert opts[:mode] == "spec"
    assert opts[:trigger] == "created"
    refute_received {:requested, _, _}
  end

  test "live minimum guards request interim analysis before report_due without requiring an event" do
    spec = create()
    freeze(spec.id, "before")
    pid = trigger()
    reconcile(pid)
    refute_received {:requested, _, _}
    freeze(spec.id, "after")
    reconcile(pid)
    assert_received {:requested, id, opts}
    assert id == spec.id
    assert opts[:mode] == "report"
    assert opts[:analysis_type] == "interim"
    assert opts[:trigger] == "sample_guard_met"
    assert {:ok, stored} = Experiments.fetch(spec.id)
    assert stored.spec["status"] == "active"
  end

  test "planned n waits for every configured cohort and supports three cohorts" do
    cohorts = Enum.map(~w(one two three), &%{id: &1, label: &1, where: %{attr: "backend", op: "eq", value: &1}})
    spec = create(%{design: %{kind: "ab", cohorts: cohorts, control: "one"}, windows: %{observation: %{start: "2026-10-08T00:00:00Z", end: "2026-10-10T00:00:00Z"}}})

    registration =
      Path.expand("../../fixtures/experiments/preregistration.valid.json", __DIR__) |> File.read!() |> Jason.decode!() |> Map.put("experiment_id", spec.id) |> Map.put("planned_n_per_cohort", 1)

    assert {:ok, _stored} = Experiments.put_preregistration(spec.id, registration)
    freeze(spec.id, "observation", ~w(one two))
    pid = trigger()
    reconcile(pid)
    refute_received {:requested, _, _}

    assert {:ok, _snapshot} =
             Snapshot.freeze(spec.id, "observation",
               revise: true,
               reason: "third cohort completed",
               context: %{
                 evaluate: fn refs, range, _ ->
                   rows = Enum.map(~w(one two three), &%{"unit_id" => &1, "at" => range["start"], "value" => 1, "censored" => false, "attrs" => %{"backend" => &1}})
                   Map.new(refs, &{&1, %{"coverage" => %{"state" => "captured"}, "observations" => rows}})
                 end
               }
             )

    reconcile(pid)
    assert_received {:requested, _, interim}
    assert interim[:analysis_type] == "interim"
    assert_received {:requested, id, confirmatory}
    assert id == spec.id
    assert confirmatory[:analysis_type] == "confirmatory"
    assert confirmatory[:trigger] == "planned_n_met"
  end

  test "automatic request failures expose the experiment and reason in logs" do
    pid = trigger(fn _, _ -> {:error, :disk_full} end)

    log =
      capture_log(fn ->
        Exchange.publish("experiment.created", %{topic: "experiment.created", experiment_id: "broken-exp", kind: "feature"})
        :sys.get_state(pid)
      end)

    assert log =~ "broken-exp"
    assert log =~ "disk_full"
  end
end
