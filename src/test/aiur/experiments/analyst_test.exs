defmodule Aiur.Experiments.AnalystTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Aiur.{Experiments, ExperimentsCLI}
  alias Aiur.Experiments.{Analyst, Paths, ReportRecords, Snapshot, Store}

  setup do
    root = Aiur.TestSupport.tmp_root!("analyst")
    previous = Application.get_env(:aiur, :experiments_dir)
    Application.put_env(:aiur, :experiments_dir, root)
    :ok = Aiur.TestSupport.ensure_pubsub_running()
    start_supervised!(Store)

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :experiments_dir, previous), else: Application.delete_env(:aiur, :experiments_dir)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    attrs = %{title: "Analyst", design: %{kind: "before_after", change: %{type: "manual", ref: "test", time: "2026-10-09T00:00:00Z"}}, metrics: [%{ref: "delivery-speed/start_to_merge"}]}
    {:ok, spec} = Experiments.create(attrs, freeze: false)
    %{id: spec.id}
  end

  defp start_analyst(opts \\ []) do
    parent = self()

    defaults = [
      start_paused?: true,
      find: fn _marker, _opts -> {:ok, nil} end,
      promote: fn number ->
        send(parent, {:promoted, number})
        :ok
      end,
      labels: fn labels ->
        send(parent, {:labels, labels})
        :ok
      end,
      create: fn attrs ->
        send(parent, {:created, attrs})
        {:ok, %{"number" => 42, "url" => "https://github.com/owner/repo/issues/42"}}
      end
    ]

    start_supervised!({Analyst, Keyword.merge(defaults, opts)})
  end

  test "concurrent duplicate requests file one nonce-marked ticket with initial dispatch labels", %{id: id} do
    start_analyst()
    results = 1..8 |> Task.async_stream(fn _ -> Experiments.analyze(id, trigger: "created", mode: "spec") end, max_concurrency: 4) |> Enum.to_list()
    assert Enum.all?(results, &match?({:ok, {:ok, %{"ticket" => %{"number" => 42}}}}, &1))
    assert_received {:created, attrs}
    assert attrs.labels == ["agent:todo", "complexity:2", "experiment-analysis"]
    assert {:ok, [request]} = Experiments.analysis_requests(id)
    assert attrs.body =~ "request=#{request["request_id"]} nonce=#{request["nonce"]}"
    refute_received {:created, _}
  end

  test "local CLI prints a blind brief, files no ticket, and defaults from real preregistration", %{id: id} do
    start_analyst()
    output = capture_io(fn -> assert ExperimentsCLI.run(verb: :analyze, argv: [id, "--local", "--json"]) == 0 end)
    data = Jason.decode!(output)
    assert data["request"]["mode"] == "spec"
    assert data["request"]["requested_by"] == "local"
    assert data["ticket"] == nil
    assert data["brief"] =~ "Sanitized inputs"
    assert data["brief"] =~ "baseline"
    refute_received {:created, _}
    refute_received {:labels, _}
    assert {:ok, records} = ReportRecords.read(id)
    assert records["first_results_read_at"] == nil

    registration = Path.expand("../../fixtures/experiments/preregistration.valid.json", __DIR__) |> File.read!() |> Jason.decode!() |> Map.put("experiment_id", id)
    assert {:ok, _stored} = Experiments.put_preregistration(id, registration)
    assert {:ok, [fulfilled]} = Experiments.analysis_requests(id)
    assert fulfilled["state"] == "fulfilled"
    assert fulfilled["submission"] == %{"mode" => "spec", "version" => 1}
    assert {:ok, report} = Experiments.analyze(id, local: true)
    assert report["request"]["mode"] == "report"
    refute report["request"]["request_id"] == fulfilled["request_id"]
    assert ExperimentsCLI.run(verb: :analyze, argv: [id, "--mode", "unknown"], error_fun: fn _ -> :ok end) == 64
    assert ExperimentsCLI.run(verb: :analyze, argv: ["unknown-experiment", "--local"], error_fun: fn _ -> :ok end) == 1
  end

  test "confirmatory supersession promotes the existing ticket without filing a second one", %{id: id} do
    start_analyst()
    assert {:ok, interim} = Experiments.analyze(id, mode: "report", trigger: "sample_guard_met")
    assert_received {:created, attrs}
    assert attrs.labels == ["agent:todo", "complexity:2", "experiment-analysis"]
    assert {:ok, confirmatory} = Experiments.analyze(id, mode: "report", analysis_type: "confirmatory", trigger: "planned_n_met")
    assert_received {:promoted, 42}
    assert confirmatory["request"]["request_id"] == interim["request"]["request_id"]
    assert confirmatory["request"]["analysis_type"] == "confirmatory"
    assert confirmatory["request"]["routing_promoted"] == true
    assert confirmatory["brief"] =~ "stored confirmatory report"
    assert {:ok, _same} = Experiments.analyze(id, mode: "report", analysis_type: "confirmatory", trigger: "planned_n_met")
    refute_received {:promoted, _}
    refute_received {:created, _}
  end

  test "blind brief excludes after outcomes even when they are already frozen", %{id: id} do
    start_analyst()

    context = fn value ->
      [
        context: %{
          evaluate: fn refs, window, _ ->
            Map.new(refs, &{&1, %{"coverage" => %{"state" => "captured"}, "observations" => [%{"unit_id" => "one", "at" => window["start"], "value" => value, "censored" => false}]}})
          end
        }
      ]
    end

    assert {:ok, _before} = Snapshot.freeze(id, "before", context.(42))
    assert {:ok, _after} = Snapshot.freeze(id, "after", context.(987_654))
    assert {:ok, data} = Experiments.analyze(id, mode: "spec", local: true)
    inputs = data["brief"] |> String.split("```json\n", parts: 2) |> List.last() |> String.trim_trailing("```\n") |> Jason.decode!()
    assert [baseline] = inputs["baseline"]
    assert baseline["window_name"] == "before"
    assert baseline["metrics"]["delivery-speed/start_to_merge"]["summary"]["median"] == 42
    refute Map.has_key?(baseline["metrics"]["delivery-speed/start_to_merge"], "observations")
    refute data["brief"] =~ "987654"
    assert {:ok, records} = ReportRecords.read(id)
    assert records["first_results_read_at"] == nil
  end

  test "uncertain creation is reconciled after restart without another POST", %{id: id} do
    parent = self()
    clock = :atomics.new(1, [])

    start_analyst(
      clock: fn -> :atomics.get(clock, 1) end,
      create: fn _ ->
        send(parent, :post)
        {:error, :timeout}
      end
    )

    assert {:error, :timeout} = Experiments.analyze(id, mode: "spec")
    assert_received :post
    assert {:ok, [pending]} = Experiments.analysis_requests(id)
    assert pending["ticket_status"] == "uncertain"
    stop_supervised!(Analyst)
    :atomics.put(clock, 1, 100_000)

    pid =
      start_analyst(
        clock: fn -> :atomics.get(clock, 1) end,
        find: fn marker, _opts ->
          send(parent, {:lookup, marker})
          {:ok, %{"number" => 42, "url" => "https://github.com/owner/repo/issues/42"}}
        end
      )

    send(pid, :retry)
    :sys.get_state(pid)
    assert_received {:lookup, marker}
    assert marker =~ pending["nonce"]
    refute_received :post
    refute_received {:created, _}
    assert {:ok, [recovered]} = Experiments.analysis_requests(id)
    assert recovered["ticket"]["number"] == 42
    assert recovered["request_id"] == pending["request_id"]
    assert File.exists?(Paths.file(id, "requests.ndjson"))
  end

  test "definite failures back off durably and alert on the third failure", %{id: id} do
    parent = self()
    clock = :atomics.new(1, [])

    pid =
      start_analyst(
        clock: fn -> :atomics.get(clock, 1) end,
        create: fn _ ->
          send(parent, :post)
          {:error, {:github, :http, %{status: 422}}}
        end,
        alert: fn request -> send(parent, {:alert, request["dispatch_attempts"]}) end
      )

    assert {:error, {:github, :http, %{status: 422}}} = Experiments.analyze(id)
    assert_received :post
    assert {:error, :ticket_retry_pending} = Experiments.analyze(id)
    refute_received :post
    send(pid, :retry)
    :sys.get_state(pid)
    refute_received :post

    for at <- [100_000, 300_000] do
      :atomics.put(clock, 1, at)
      send(pid, :retry)
      :sys.get_state(pid)
      assert_received :post
    end

    assert_received {:alert, 3}
    assert {:ok, [request]} = Experiments.analysis_requests(id)
    assert request["dispatch_attempts"] == 3
    assert request["next_attempt_ms"] == 540_000
    assert request["state"] == "open"
  end

  test "restart reconciliation fulfills a persisted submit whose request append failed", %{id: id} do
    assert {:ok, pending} = Experiments.request_analysis(id, "spec", trigger: "created")
    path = Paths.file(id, "requests.ndjson")
    File.rename!(path, path <> ".saved")
    File.mkdir!(path)
    registration = Path.expand("../../fixtures/experiments/preregistration.valid.json", __DIR__) |> File.read!() |> Jason.decode!() |> Map.put("experiment_id", id)
    assert {:error, :eisdir} = Experiments.put_preregistration(id, registration)
    assert {:ok, records} = ReportRecords.read(id)
    assert records["preregistration"]["experiment_id"] == id
    File.rmdir!(path)
    File.rename!(path <> ".saved", path)
    stop_supervised!(Store)
    start_supervised!(Store)
    start_analyst()
    assert {:ok, data} = Experiments.analyze(id, mode: "spec", trigger: "created", local: true)
    assert data["request"]["request_id"] == pending["request_id"]
    assert data["request"]["state"] == "fulfilled"
    assert data["request"]["submission"] == %{"mode" => "spec", "version" => 1}
    refute_received {:created, _}
  end

  test "periodic reconciliation requests the planned confirmatory look from actual completed counts", %{id: id} do
    alias Aiur.Events.Exchange
    alias Aiur.Experiments.AnalystTrigger
    unless Process.whereis(Exchange), do: start_supervised!(Exchange)

    registration =
      Path.expand("../../fixtures/experiments/preregistration.valid.json", __DIR__) |> File.read!() |> Jason.decode!() |> Map.put("experiment_id", id) |> Map.put("planned_n_per_cohort", 1)

    assert {:ok, _stored} = Experiments.put_preregistration(id, registration)

    context = [
      context: %{
        evaluate: fn refs, window, _ ->
          Map.new(refs, &{&1, %{"coverage" => %{"state" => "captured"}, "observations" => [%{"unit_id" => window["start"], "at" => window["start"], "value" => 1, "censored" => false}]}})
        end
      }
    ]

    for window <- ["before", "after"], do: assert({:ok, _snapshot} = Snapshot.freeze(id, window, context))
    parent = self()
    pid = start_supervised!({AnalystTrigger, start_paused?: true, enabled: fn -> true end, request: fn experiment, opts -> send(parent, {:planned, experiment, opts}) end})
    send(pid, :reconcile)
    :sys.get_state(pid)
    assert_received {:planned, ^id, opts}
    assert opts[:mode] == "report"
    assert opts[:analysis_type] == "confirmatory"
    assert opts[:trigger] == "planned_n_met"
  end

  test "failed confirmatory promotion retries autonomously with backoff and never creates another ticket", %{id: id} do
    parent = self()
    clock = :atomics.new(1, [])
    attempts = :atomics.new(1, [])

    pid =
      start_analyst(
        clock: fn -> :atomics.get(clock, 1) end,
        promote: fn number ->
          send(parent, {:promotion_attempt, number})
          if :atomics.add_get(attempts, 1, 1) == 1, do: {:error, :timeout}, else: :ok
        end
      )

    assert {:ok, _interim} = Experiments.analyze(id, mode: "report")
    assert_received {:created, _}
    assert {:error, :timeout} = Experiments.analyze(id, mode: "report", analysis_type: "confirmatory")
    assert_received {:promotion_attempt, 42}
    send(pid, :retry)
    :sys.get_state(pid)
    refute_received {:promotion_attempt, _}
    :atomics.put(clock, 1, 100_000)
    send(pid, :retry)
    :sys.get_state(pid)
    assert_received {:promotion_attempt, 42}
    assert {:ok, [request]} = Experiments.analysis_requests(id)
    assert request["routing_promoted"] == true
    refute_received {:created, _}
  end
end
