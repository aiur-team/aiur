defmodule Aiur.Experiments.AnalystLoopTest do
  @moduledoc "Offline proof of request -> events -> stats -> pre-registration -> report -> page on the fixture-feature experiment. One file: the stages share one fixture and order."
  use ExUnit.Case, async: false
  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest, only: [live: 2]
  alias Aiur.{Experiments, ExperimentsCLI}
  alias Aiur.Experiments.{Evidence, ReportRecords, Snapshot, StatsRunner, Store}
  alias Aiur.Experiments.Sources.Common
  alias Aiur.TestSupport.RuntimeChildren
  alias AiurWeb.Endpoint
  @endpoint Endpoint
  import ExUnit.CaptureIO

  @fixtures Path.expand("../../fixtures/experiments", __DIR__)
  @metric "delivery-speed/start_to_merge"
  @rank ~w(not-enough-data underpowered inconclusive no-effect-detected significant)
  @now ~U[2026-10-22 00:00:00Z]

  setup do
    root = Aiur.TestSupport.tmp_root!("analyst-loop")
    previous_base = Application.get_env(:aiur, :repo_base_root)
    previous = Application.get_env(:aiur, :experiments_dir)
    Application.put_env(:aiur, :repo_base_root, Path.join(root, "repo"))
    Application.put_env(:aiur, :experiments_dir, root)

    previous_endpoint = Application.get_env(:aiur, Endpoint)
    Application.put_env(:aiur, Endpoint, Keyword.merge(previous_endpoint || [], server: false, dashboard_auth_required: false, secret_key_base: String.duplicate("s", 64)))

    on_exit(fn ->
      if previous_endpoint, do: Application.put_env(:aiur, Endpoint, previous_endpoint), else: Application.delete_env(:aiur, Endpoint)
      if previous, do: Application.put_env(:aiur, :experiments_dir, previous), else: Application.delete_env(:aiur, :experiments_dir)
      if previous_base, do: Application.put_env(:aiur, :repo_base_root, previous_base), else: Application.delete_env(:aiur, :repo_base_root)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    :ok = Aiur.TestSupport.ensure_pubsub_running()
    :ok = RuntimeChildren.ensure_aiur_supervisor_running()
    start_supervised!(StatsRunner)
    start_supervised!({Store, catalog_context: %{reduce_dir: Path.expand("../../../../analytics", __DIR__)}})
    Aiur.TestSupport.start_owned_endpoint!()
    :ok
  end

  defp build_conn, do: Phoenix.ConnTest.build_conn() |> Plug.Conn.put_req_header("authorization", "Basic " <> Base.encode64("operator:test-dashboard-secret"))

  defp fixture(name), do: @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()

  defp create(id) do
    attrs = fixture("fixture-feature/spec.json") |> Map.put("id", id) |> Map.drop(["created_at", "updated_at", "registered_at"])
    assert {:ok, spec} = Experiments.create(attrs, freeze: false)
    spec
  end

  # 40 tickets per window, one every 6 hours; the after window is 20% faster.
  defp context do
    %{
      clock: @now,
      evaluate: fn refs, window, _ctx ->
        start = Common.timestamp(window["start"])
        {prefix, factor} = if window["start"] == "2026-10-11T00:00:00Z", do: {"a", 0.8}, else: {"b", 1.0}

        rows =
          for i <- 0..39 do
            at = start |> DateTime.add(i * 6 * 3600) |> DateTime.to_iso8601()
            j = if prefix == "a", do: 11 * i + 5, else: i
            value = round((3_600_000 + rem(j * 7919, 40) * 90_000 + rem(j * 104_729, 97) * 200_000) * factor)
            %{"unit_id" => "#{prefix}#{i}", "at" => at, "value" => value, "started_at" => at, "finished_at" => at, "censored" => false, "attrs" => %{"complexity" => "#{2 + rem(i, 2)}"}}
          end

        Map.new(refs, &{&1, %{"coverage" => %{"state" => "captured"}, "observations" => rows}})
      end
    }
  end

  defp sample(at, cap), do: %{"timestamp" => at, "boot_id" => "b1", "record_id" => at, "attributes" => %{"fleet_agents_max" => cap, "fleet_agents_effective" => cap}}

  defp run(at, conclusion, id),
    do: %{"id" => id, "name" => "CI", "head_branch" => "main", "event" => "push", "status" => "completed", "conclusion" => conclusion, "updated_at" => at, "html_url" => "https://ci/#{id}"}

  defp event_opts do
    records = [sample("2026-09-29T00:00:00Z", 8), sample("2026-10-15T00:00:00Z", 8), sample("2026-10-15T06:00:00Z", 4), sample("2026-10-16T06:00:00Z", 4), sample("2026-10-16T08:00:00Z", 8)]
    ci_pr = %{"number" => 9100, "mergedAt" => "2026-10-14T12:00:00Z", "title" => "Tune CI", "files" => %{"nodes" => [%{"path" => ".github/workflows/ci.yml"}]}}
    epic_pr = %{"number" => 9002, "mergedAt" => "2026-10-12T12:00:00Z", "title" => "Epic piece", "closingIssuesReferences" => %{"nodes" => [%{"parent" => %{"number" => 9001}}]}}
    runs = [run("2026-10-13T02:00:00Z", "failure", 1), run("2026-10-13T08:00:00Z", "success", 2)]

    [records_fun: fn _ -> {records, []} end, alert_files: [], now: @now, github_fun: fn _, _, _, _ -> {%{"pulls" => [ci_pr, epic_pr], "runs" => runs}, []} end]
  end

  defp registration(id) do
    fixture("preregistration.valid.json")
    |> Map.put("experiment_id", id)
    |> Map.put("primary_metrics", [%{"id" => @metric, "expected" => "decrease"}])
    |> put_in(["mde", "metric"], @metric)
  end

  defp frozen(id) do
    for name <- ["before", "after"], do: assert({:ok, _snapshot} = Snapshot.freeze(id, name, context: context()))
  end

  defp report(stats, registration, events, label_fun \\ & &1) do
    row = stats["report_results"] |> hd() |> Map.put("modifiers", ["confounded"]) |> label_fun.()

    confounders =
      Enum.map(events["events"], fn event ->
        red? = event["kind"] == "main_red"

        %{
          "event_id" => event["event_id"],
          "kind" => event["kind"],
          "at" => event["at"],
          "ref" => event["ref"] || event["event_id"],
          "title" => if(event["title"] in [nil, ""], do: event["kind"], else: event["title"]),
          "classification" => if(red?, do: "main-red", else: "unrelated-change"),
          "affects" => [@metric],
          "bias" => "unknown",
          "severity" => if(red?, do: "high", else: "low"),
          "handling" => "noted",
          "note" => "Reviewed against the after window."
        }
      end)

    fixture("report.valid.json")
    |> Map.put("results", [row])
    |> Map.put("labels", Enum.sort(Enum.uniq([row["label"], "confounded"])))
    |> Map.put("confounders", confounders)
    |> put_in(["preregistration", "record"], registration)
    |> put_in(["header", "experiment_id"], registration["experiment_id"])
    |> put_in(["header", "analysis_type"], "interim")
    |> put_in(["header", "stats_snapshot_hash"], stats["snapshot_hash"])
    |> put_in(["header", "events_snapshot_hash"], events["snapshot_hash"])
    |> put_in(["header", "preregistration_hash"], Evidence.hash(registration))
  end

  defp submit(id, report) do
    parent = self()

    capture_io(fn ->
      capture_io(:stderr, fn -> send(parent, {:exit, ExperimentsCLI.run(verb: :report_submit, argv: [id, "--contract-json", Jason.encode!(report)])}) end)
    end)
  end

  test "analyst loop: events, pre-registration, report and rejection paths" do
    id = "fixture-feature"
    spec = create(id)
    assert {:ok, request} = Experiments.request_analysis(spec.id, "report")

    assert {:ok, registered} = Experiments.put_preregistration(id, registration(id))
    assert registered["post_hoc"] == false
    frozen(id)

    assert {:ok, events} = Experiments.events(id, event_opts())
    assert events["events"] |> Enum.map(& &1["kind"]) |> Enum.sort() == ~w(capacity_change main_red merged_pr merged_pr)
    assert [%{"attrs" => %{"epic" => 9001}}] = Enum.filter(events["events"], &(&1["kind"] == "merged_pr" and &1["attrs"]["epic"]))
    assert Enum.all?(events["events"], &(&1["window"] == "after"))

    assert {:ok, stats} = Experiments.stats(id)
    [row] = stats["report_results"]
    assert row["n"] == %{"before" => 40, "after" => 40}
    assert row["median"]["after"] < row["median"]["before"]

    good = report(stats, registered, events)

    # omitting the main-red confounder row is rejected and stores nothing
    omitted = Map.update!(good, "confounders", fn rows -> Enum.reject(rows, &(&1["kind"] == "main_red")) end)
    submit(id, omitted)
    assert_received {:exit, 1}
    assert {:ok, %{"reports" => []}} = ReportRecords.read(id)

    # upgrading a label above the engine's is rejected
    engine = row["engine_label"]
    assert engine != "significant", "fixture must leave room to upgrade, got #{engine}"
    upgraded_label = Enum.at(@rank, Enum.find_index(@rank, &(&1 == engine)) + 1)
    upgraded = report(stats, registered, events, &Map.put(&1, "label", upgraded_label))
    submit(id, upgraded)
    assert_received {:exit, 1}
    assert {:ok, %{"reports" => []}} = ReportRecords.read(id)

    # the golden report, with the start-to-merge metric marked confounded, stores as v1
    submit(id, good)
    assert_received {:exit, 0}
    assert {:ok, %{"reports" => [%{"header" => %{"report_version" => 1}, "results" => [%{"modifiers" => ["confounded"]}]}]}} = ReportRecords.read(id)
    assert {:ok, [%{"request_id" => request_id, "state" => "fulfilled"}]} = Experiments.analysis_requests(id)
    assert request_id == request["request_id"]

    page_check(id)
  end

  test "pre-registration after a results read is post hoc" do
    id = "fixture-late"
    create(id)
    frozen(id)
    assert {:ok, _detail} = Experiments.fetch(id)
    assert {:ok, %{"first_results_read_at" => read_at}} = ReportRecords.read(id)
    assert read_at
    assert {:ok, late} = Experiments.put_preregistration(id, registration(id))
    assert late["post_hoc"] == true
  end

  # U2: the real page renders the stored report: sections in order, label chips with n and CI, one confounder row per event.
  defp page_check(id) do
    # The page turns a failed read into an empty state and logs the cause only to the log file (#5742).
    {{:ok, _view, html}, log} = ExUnit.CaptureLog.with_log(fn -> live(build_conn(), "/experiments/#{id}") end)
    doc = Floki.parse_document!(html)

    report =
      case Floki.find(doc, "#exp-report") do
        [report] ->
          report

        found ->
          reasons = doc |> Floki.find("[data-empty-reason]") |> Enum.flat_map(&Floki.attribute(&1, "data-empty-reason"))
          page = doc |> Floki.find("#experiments-page") |> Floki.text(sep: " ") |> String.slice(0, 500)
          flunk("expected one #exp-report, found #{length(found)}; empty states #{inspect(reasons)}: #{page}\nlog:\n#{log}")
      end

    text = Floki.text(report, sep: "\n")

    headings = ~w(Summary Pre-registration) ++ ["Design and sample", "Results", "Confounders reviewed", "Sensitivity analyses", "Threats to validity", "Recommendation", "Reproduce"]
    positions = Enum.map(headings, fn heading -> text |> :binary.match(heading) |> elem(0) end)
    assert positions == Enum.sort(positions)
    assert text =~ ~r/Labels: .*\(n=after=40 \/ before=40, effect .*95% CI \[/

    [confounders] = report |> Floki.find("table") |> Enum.filter(&(Floki.text(&1) =~ "main_red"))
    assert length(Floki.find(confounders, "tbody tr")) == 4
  end
end
