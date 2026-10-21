defmodule AiurWeb.ExperimentsLiveTest do
  use Aiur.TestSupport
  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  alias AiurWeb.Endpoint
  @endpoint Endpoint

  defmodule Facade do
    def metric_catalog, do: fail(:metric_catalog) || %{metrics: %{}}
    def status, do: fail(:status) || state().status
    def list, do: fail(:list) || state().list
    def fetch(id), do: fail(:fetch) || Map.get(state().details, id, {:error, :not_found})
    def chart_detail(id, _opts), do: fetch(id)
    defp state, do: Application.fetch_env!(:aiur, :experiment_live_fixture)

    defp fail(read) do
      case get_in(state(), [:fail, read]) do
        nil -> nil
        :noproc -> exit({:noproc, {GenServer, :call, [Aiur.Experiments.Store, read, 5_000]}})
        error -> raise error
      end
    end

    def subscribe, do: Phoenix.PubSub.subscribe(Aiur.PubSub, "experiment-live-test")
  end

  setup do
    previous = Map.new([:experiments_facade, :experiment_live_fixture, Endpoint], &{&1, Application.get_env(:aiur, &1)})
    Application.put_env(:aiur, :experiments_facade, Facade)
    Application.put_env(:aiur, Endpoint, Keyword.merge(previous[Endpoint] || [], server: false, dashboard_auth_required: false, secret_key_base: String.duplicate("s", 64)))
    fixture()
    Aiur.TestSupport.start_owned_endpoint!()
    on_exit(fn -> for {key, value} <- previous, do: restore(key, value) end)
    :ok
  end

  test "empty store names creation paths without chart frames" do
    {:ok, view, html} = live(build_conn(), "/experiments")
    assert html =~ "Pause new starts"
    refute html =~ "Pause state unknown"
    assert has_element?(view, "#ax-pause[aria-checked=false]")
    assert has_element?(view, "[data-empty-reason=no_experiments]")
    assert html =~ "version bump or release"
    assert html =~ "tagged feature epic merge"
    assert html =~ "analyst request"
    refute has_element?(view, "#exp-charts")
  end

  test "disabled and unreadable stores remain distinct and never expose paths" do
    for {reason, state, copy} <- [{:disabled, "component_off", "Experiments are not enabled"}, {{:bad, "/private/store"}, "store_unreadable", "could not be read"}] do
      fixture(status: %{available?: false, store: {:error, reason}, capture: :off})
      {:ok, view, html} = live(build_conn(), "/experiments")
      assert has_element?(view, "[data-empty-reason=#{state}]")
      assert html =~ copy
      refute html =~ "/private/store"
      refute has_element?(view, "#experiments-capture-off")
    end
  end

  test "a first-request read that raises or exits renders the neutral read_failed state, not a 500" do
    cold_ets = %ArgumentError{message: "the table identifier does not refer to an existing ETS table"}
    unreadable = %File.Error{reason: :eacces, action: "read file", path: "result.json"}

    for {fail, cause} <- [
          {%{status: :noproc}, "no process"},
          {%{metric_catalog: cold_ets}, "existing ETS table"},
          {%{list: cold_ets}, "existing ETS table"},
          {%{fetch: unreadable}, "permission denied"}
        ] do
      populated()
      fixture(Map.put(Application.fetch_env!(:aiur, :experiment_live_fixture), :fail, fail))

      log =
        capture_log(fn ->
          html = build_conn() |> get("/experiments") |> html_response(200)
          assert html =~ ~s(data-empty-reason="read_failed")
          {:ok, view, _html} = live(build_conn(), "/experiments")
          assert has_element?(view, "[data-empty-reason=read_failed]", "could not be loaded")
          refute has_element?(view, "[data-empty-reason=store_unreadable]")
          refute has_element?(view, "#exp-detail")
        end)

      assert log =~ "experiments page"
      assert log =~ cause
    end
  end

  test "capture off still renders specification and unavailable evidence" do
    populated()
    {:ok, view, html} = live(build_conn(), "/experiments/first")
    assert has_element?(view, "#experiments-capture-off")
    assert has_element?(view, ".exp-index a[aria-current=page]", "First")
    assert html =~ "A registered hypothesis"
    assert html =~ "Evidence unavailable"
    assert html =~ "Unknown unit"
    refute html =~ "Frozen baseline</dt><dd>0"
    assert html =~ "delivery-speed/start_to_merge"
    assert has_element?(view, "#exp-charts")
    assert has_element?(view, "#exp-report")
  end

  test "frozen baseline provenance renders and updates only on facade notifications" do
    populated()
    frozen = %{"window_name" => "before", "revision" => 2, "computed_at" => "2026-10-10T00:00:00Z", "aiur_version" => "0.0.9", "sha256" => "baseline-hash"}
    state = Application.fetch_env!(:aiur, :experiment_live_fixture)
    state = update_in(state, [:details, "first"], fn {:ok, detail} -> {:ok, Map.merge(detail, %{snapshots: [frozen], pack_changed_since_freeze: true})} end)
    Application.put_env(:aiur, :experiment_live_fixture, state)
    {:ok, view, _html} = live(build_conn(), "/experiments/first")
    assert has_element?(view, "#exp-baseline", "Revision 2")
    assert has_element?(view, "#exp-baseline", "2026-10-10T00:00:00Z")
    assert has_element?(view, "#exp-baseline", "Aiur 0.0.9")
    assert has_element?(view, "#exp-baseline", "baseline-hash")
    assert render(view) =~ "Metric pack definitions changed"
    populated()
    send(view.pid, :irrelevant)
    assert has_element?(view, "#exp-baseline")
    send(view.pid, {:experiments_changed, "first"})
    refute has_element?(view, "#exp-baseline")
    assert render(view) =~ "Evidence unavailable"
  end

  test "stored analysis supplies guarded index and detail evidence and refreshes" do
    populated()
    analysis = "test/aiur/experiments/fixtures/results/page_analysis.json" |> File.read!() |> Jason.decode!() |> Map.fetch!("body")
    state = Application.fetch_env!(:aiur, :experiment_live_fixture)
    state = update_in(state, [:details, "first"], fn {:ok, detail} -> {:ok, Map.put(detail, :analysis, analysis)} end)
    Application.put_env(:aiur, :experiment_live_fixture, state)
    {:ok, view, html} = live(build_conn(), "/experiments/first")
    assert has_element?(view, ".exp-index a", "n 4/10")
    assert has_element?(view, ".exp-index a", "analyst: confounded")
    assert has_element?(view, ".exp-table", "not enough data (n 4 of 10)")
    assert has_element?(view, ".exp-table", "before: median 100.06")
    refute has_element?(view, "[data-empty-reason=evidence_pending]")
    copy = html |> Floki.parse_document!() |> Floki.find("#experiments-page") |> Floki.text()
    refute copy =~ ~r/\b(?:win|better|worse|regress\w*|improv\w*)\b/i
    populated()
    send(view.pid, {:experiments_changed, "first"})
    assert has_element?(view, "[data-empty-reason=evidence_pending]")
    refute has_element?(view, ".exp-index a", "n 4/10")
  end

  test "default desktop detail refreshes on facade change" do
    populated()
    {:ok, view, _html} = live(build_conn(), "/experiments")
    populated("Updated default detail")
    send(view.pid, {:experiments_changed, "first"})
    assert render(view) =~ "Updated default detail"
  end

  test "index chooses first detail without changing the mobile index URL" do
    populated()
    {:ok, view, _html} = live(build_conn(), "/experiments")
    assert has_element?(view, "#experiments-page[data-selection=index]")
    assert has_element?(view, "#exp-detail h2", "First")
    render_click(element(view, ".exp-index a", "Second"))
    assert_patch(view, "/experiments/second")
    assert has_element?(view, "#exp-detail h2", "Second")
    assert has_element?(view, "#experiments-page[data-selection=detail]")
    render_click(element(view, ".exp-back"))
    assert_patch(view, "/experiments")
  end

  test "unknown id has its own state when the store has no experiments" do
    {:ok, view, _html} = live(build_conn(), "/experiments/missing")
    assert has_element?(view, "[data-empty-reason=not_found]", "Experiment not found")
    refute has_element?(view, "[data-empty-reason=no_experiments]")
  end

  test "unknown id has a shell state and link back" do
    populated()
    {:ok, view, _html} = live(build_conn(), "/experiments/missing")
    assert has_element?(view, "[data-empty-reason=not_found]", "Experiment not found")
    assert has_element?(view, "[data-empty-reason=not_found] a[href='/experiments']")
  end

  test "facade notifications refresh index and open detail, unrelated messages do not" do
    populated()
    {:ok, view, _html} = live(build_conn(), "/experiments/first")
    populated("Changed hypothesis")
    send(view.pid, :irrelevant)
    assert render(view) =~ "A registered hypothesis"
    send(view.pid, {:experiments_changed, "second"})
    assert render(view) =~ "A registered hypothesis"
    Phoenix.PubSub.broadcast(Aiur.PubSub, "experiment-live-test", {:experiments_changed, "first"})
    assert render(view) =~ "Changed hypothesis"
    fixture()
    send(view.pid, {:experiments_changed, :all})
    assert has_element?(view, "[data-empty-reason=not_found]")
    refute has_element?(view, ".exp-index a")
    refute has_element?(view, "#exp-detail")
  end

  test "analyst report renders a table and sanitized content with attributed time" do
    populated()
    written_at = report_time(-86_400)

    report(%{
      markdown: "# Results\n\n| Metric | p |\n| --- | ---: |\n| latency | 0.01 |\n\n/home/alice/private/report.csv ghp_" <> String.duplicate("a", 36),
      author: "Experiment analyst",
      written_at: written_at,
      results_at: written_at
    })

    {:ok, view, html} = live(build_conn(), "/experiments/first")
    assert has_element?(view, "#exp-report h3", "Analyst report")
    assert has_element?(view, "#exp-report h3", "Results")
    assert has_element?(view, "#exp-report table td", "0.01")
    assert has_element?(view, "#exp-report", "Experiment analyst")
    assert has_element?(view, "#exp-report time[title='#{written_at}']", "1d ago")
    refute has_element?(view, "#exp-report", "Superseded report")
    refute has_element?(view, "#exp-report-stale")
    refute html =~ "/home/alice"
    refute html =~ "ghp_"
    assert has_element?(view, "#exp-report", "[REDACTED")
  end

  test "pending report explains absence and updates on the facade notification" do
    populated()
    {:ok, view, _html} = live(build_conn(), "/experiments/first")
    assert has_element?(view, "#exp-report", "The analyst has not written a report for this experiment yet.")
    refute has_element?(view, "#exp-report time")
    report(%{markdown: "Report arrived", author: "Analyst", written_at: report_time(-86_400), results_at: nil})
    send(view.pid, {:experiments_changed, "first"})
    assert has_element?(view, "#exp-report", "Report arrived")
    refute has_element?(view, "#exp-report", "The analyst has not written")
  end

  test "results changed notice carries both report and result times" do
    populated()
    written_at = report_time(-172_800)
    results_at = report_time(-86_400)
    report(%{markdown: "Earlier report", author: "Analyst", written_at: written_at, results_at: results_at})
    {:ok, view, _html} = live(build_conn(), "/experiments/first")
    assert has_element?(view, "#exp-report-stale", "Results changed after this report was written")
    assert has_element?(view, "#exp-report-stale time[datetime='#{written_at}'][title='#{written_at}']")
    assert has_element?(view, "#exp-report-stale time[datetime='#{results_at}'][title='#{results_at}']")
  end

  test "unavailable report content and unknown metadata are explicit" do
    populated()
    report(%{markdown: String.duplicate("x", 128_001), author: nil, written_at: "invalid", results_at: nil})
    {:ok, view, _html} = live(build_conn(), "/experiments/first")
    assert has_element?(view, "#exp-report", "The analyst report could not be displayed.")
    assert has_element?(view, "#exp-report", "Unknown analyst")
    assert has_element?(view, "#exp-report", "Unknown time")
    refute has_element?(view, "#exp-report .ticket-context-markdown")
    refute has_element?(view, "#exp-report time")
    refute has_element?(view, "#exp-report-stale")
  end

  defp report_time(offset), do: DateTime.utc_now() |> DateTime.add(offset, :second) |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp report(report) do
    stored = "test/fixtures/experiments/report.valid.json" |> File.read!() |> Jason.decode!()
    stored = stored |> Map.put("summary", report.markdown) |> put_in(["header", "generated_at"], report.written_at) |> put_in(["header", "analyst"], %{"agent" => report.author})
    state = Application.fetch_env!(:aiur, :experiment_live_fixture)

    state =
      update_in(state, [:details, "first"], fn {:ok, detail} ->
        {:ok,
         Map.merge(detail, %{
           report_records: %{"reports" => [Map.put(stored, "summary", "Superseded report"), stored]},
           snapshots: [%{"computed_at" => report.results_at}, %{"computed_at" => report.written_at}]
         })}
      end)

    Application.put_env(:aiur, :experiment_live_fixture, state)
  end

  defp fixture(opts \\ []) do
    Application.put_env(:aiur, :experiment_live_fixture, Map.merge(%{status: %{available?: true, store: :ok, capture: :off}, list: {:ok, []}, details: %{}}, Map.new(opts)))
  end

  defp populated(hypothesis \\ "A registered hypothesis") do
    spec = "test/aiur/experiments/fixtures/valid_line.json" |> File.read!() |> Jason.decode!() |> Map.fetch!("spec")
    summaries = for {id, title} <- [{"first", "First"}, {"second", "Second"}], do: %{id: id, title: title, status: "active", created_at: "2026-10-09T00:00:00Z"}
    details = Map.new(summaries, fn row -> {row.id, {:ok, %{spec: Map.merge(spec, %{"id" => row.id, "title" => row.title, "hypothesis" => hypothesis, "min_samples" => 10}), phase: :collecting}}} end)
    fixture(list: {:ok, summaries}, details: details)
  end

  defp build_conn, do: Phoenix.ConnTest.build_conn() |> Plug.Conn.put_req_header("authorization", "Basic " <> Base.encode64("operator:test-dashboard-secret"))

  defp restore(key, nil), do: Application.delete_env(:aiur, key)
  defp restore(key, value), do: Application.put_env(:aiur, key, value)
end
