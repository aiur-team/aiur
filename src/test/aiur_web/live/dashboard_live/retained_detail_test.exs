defmodule AiurWeb.DashboardLive.RetainedDetailTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  import AiurWeb.DashboardLiveSupport
  import AiurWeb.DashboardLiveSupport.DecisionFixtures
  import AiurWeb.DashboardLiveSupport.Processes

  alias Aiur.DecisionStore
  alias AiurWeb.DashboardLiveSupport.StoreStubs.CountingDetailStore

  @endpoint AiurWeb.Endpoint

  test "a direct Decision URL resolves a retained record outside the 50-item overview" do
    orchestrator_name = Module.concat(__MODULE__, :RetainedDetailOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :RetainedDetailStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 507}}}
      end)

    oldest = request_dashboard_decision(store, "retained-oldest", "reversible", now: ~U[2026-07-13 08:00:00Z])

    for index <- 1..50 do
      request_dashboard_decision(
        store,
        "retained-newer-#{index}",
        "reversible",
        now: DateTime.add(oldest.created_at, index, :second)
      )
    end

    refute Enum.any?(DecisionStore.recent_decisions(50, store), &(&1.decision_id == oldest.decision_id))
    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name
    )

    {:ok, _view, html} = live(build_conn(), "/commands/#{oldest.decision_id}")
    assert html =~ oldest.decision_id
    assert html =~ "Should the dashboard ship this change?"
    refute html =~ "Command not found"
  end

  test "a selected retained Decision remains visible when the stale URL filter excludes its lifecycle" do
    orchestrator_name = Module.concat(__MODULE__, :ResolvedSelectionOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :ResolvedSelectionStore)
    detail_store_name = Module.concat(__MODULE__, :ResolvedSelectionDetailStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 5_078}}}
      end)

    overview = request_dashboard_decision(store, "resolved-selected-filter")

    resolved =
      store
      |> replace_dashboard_decision(overview,
        question: "This retained decision is resolved.",
        reversibility: "reversible",
        option_label: "No further action"
      )
      |> Map.put(:decision_status, :resolved)

    start_versioned_detail_store(detail_store_name, overview, resolved)
    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: detail_store_name,
      control_center_cache: false
    )

    {:ok, _view, html} = live(build_conn(), "/commands/#{resolved.decision_id}?filter=open")
    assert html =~ "This retained decision is resolved."
    assert html =~ "Resolved"
    refute html =~ "No Commands match this filter."
  end

  test "unavailable or indeterminate detail excludes the matching stale overview row and rejects answers" do
    orchestrator_name = Module.concat(__MODULE__, :StaleAnswerOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :StaleAnswerStore)
    detail_store_name = Module.concat(__MODULE__, :StaleAnswerDetailStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 5_081}}}
      end)

    overview = request_dashboard_decision(store, "stale-detail-answer")
    start_stale_detail_store(detail_store_name, overview, :unavailable)
    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: detail_store_name,
      control_center_cache: false,
      dashboard_writable: true
    )

    for detail_status <- [:unavailable, :indeterminate] do
      assert :ok = GenServer.call(detail_store_name, {:set_detail_status, detail_status})

      {:ok, view, html} = live(build_conn(), "/commands/#{overview.decision_id}")
      assert html =~ if(detail_status == :unavailable, do: "Command unavailable", else: "Command presence unknown")
      refute html =~ "Should the dashboard ship this change?"
      refute html =~ ~s(phx-submit="answer-decision")

      _html =
        render_submit(view, "answer-decision", %{
          "decision_id" => overview.decision_id,
          "answer" => %{"choice" => "option:ship", "rationale" => "Must not use stale overview data"}
        })

      decision_id = overview.decision_id
      refute_receive {:stale_detail_answer, ^decision_id, _payload, _opts}, 100
    end
  end

  test "unavailable or indeterminate detail excludes the matching stale overview row and rejects revisions" do
    orchestrator_name = Module.concat(__MODULE__, :StaleRevisionOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :StaleRevisionStore)
    detail_store_name = Module.concat(__MODULE__, :StaleRevisionDetailStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 5_082}}}
      end)

    requested = request_dashboard_decision(store, "stale-detail-revision")

    assert {:ok, _accepted} =
             DecisionStore.answer(
               requested.decision_id,
               %{
                 "idempotency_key" => "stale-detail-answer",
                 "expected_version" => requested.version,
                 "option_id" => "ship"
               },
               [actor: %{kind: :operator, id: "test"}],
               store
             )

    assert {:ok, overview} = DecisionStore.get(requested.decision_id, store)
    start_stale_detail_store(detail_store_name, overview, :unavailable)
    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: detail_store_name,
      control_center_cache: false,
      dashboard_writable: true
    )

    for detail_status <- [:unavailable, :indeterminate] do
      assert :ok = GenServer.call(detail_store_name, {:set_detail_status, detail_status})

      {:ok, view, html} = live(build_conn(), "/commands/#{overview.decision_id}")
      assert html =~ if(detail_status == :unavailable, do: "Command unavailable", else: "Command presence unknown")
      refute has_element?(view, "#decision-#{overview.decision_id}")
      refute html =~ ~s(phx-submit="revise-decision")

      _html =
        render_submit(view, "revise-decision", %{
          "decision_id" => overview.decision_id,
          "revision" => %{
            "choice" => "custom",
            "custom_response" => "Must not use stale overview data",
            "reason" => "The exact retained detail is unavailable"
          }
        })

      decision_id = overview.decision_id
      refute_receive {:stale_detail_revision, ^decision_id, _payload, _opts}, 100
    end
  end

  test "a retained version refresh clears an answer draft and confirmation" do
    orchestrator_name = Module.concat(__MODULE__, :AnswerRefreshOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :AnswerRefreshStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 5_079}}}
      end)

    initial = request_dashboard_decision(store, "answer-refresh", "irreversible")
    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      control_center_cache: false,
      control_center_reload_timer: fn pid, message, _delay -> send(pid, message) end,
      dashboard_writable: true
    )

    {:ok, view, _html} = live(build_conn(), "/commands/#{initial.decision_id}")

    draft_html =
      render_change(view, "decision-action-change", %{
        "decision_id" => initial.decision_id,
        "answer" => %{
          "choice" => "custom",
          "custom_response" => "Draft from the old retained version"
        }
      })

    assert draft_html =~ "Draft from the old retained version"

    refreshed =
      replace_dashboard_decision(store, initial,
        question: "Destroy the refreshed answer target?",
        reversibility: "irreversible",
        option_label: "Destroy the refreshed target"
      )

    assert eventually(fn -> render(view) =~ "Destroy the refreshed answer target?" end, 80)
    refreshed_html = render(view)
    assert refreshed_html =~ "Destroy the refreshed answer target?"
    refute refreshed_html =~ "Draft from the old retained version"

    html =
      render_submit(view, "answer-decision", %{
        "decision_id" => refreshed.decision_id,
        "answer" => %{
          "choice" => "option:ship",
          "confirmed" => "true",
          "rationale" => "Confirmed after the retained refresh"
        }
      })

    assert html =~ "Answer recorded"

    assert eventually(fn ->
             {:ok, current} = DecisionStore.get(refreshed.decision_id, store)
             not is_nil(current.answer)
           end)
  end

  test "a retained version refresh clears a revision draft and confirmation" do
    orchestrator_name = Module.concat(__MODULE__, :RevisionRefreshOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :RevisionRefreshStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 5_080}}}
      end)

    overview = request_dashboard_decision(store, "revision-refresh", "irreversible")

    assert {:ok, _accepted} =
             DecisionStore.answer(
               overview.decision_id,
               %{
                 "idempotency_key" => "revision-refresh-original",
                 "expected_version" => overview.version,
                 "option_id" => "ship"
               },
               [actor: %{kind: :operator, id: "test"}],
               store
             )

    {:ok, initial} = DecisionStore.get(overview.decision_id, store)

    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      control_center_cache: false,
      control_center_reload_timer: fn pid, message, _delay -> send(pid, message) end,
      dashboard_writable: true
    )

    {:ok, view, _html} = live(build_conn(), "/commands/#{initial.decision_id}")

    draft_html =
      render_change(view, "decision-revision-change", %{
        "decision_id" => initial.decision_id,
        "revision" => %{
          "choice" => "option:ship",
          "confirmed" => "true",
          "reason" => "Draft from the old active action"
        }
      })

    assert draft_html =~ "Draft from the old active action"
    assert draft_html =~ ~s(name="revision[confirmed]" value="true" checked)

    refreshed =
      store
      |> replace_dashboard_decision(initial,
        question: "Destroy the refreshed revision target?",
        reversibility: "irreversible",
        option_label: "Destroy the refreshed revision target"
      )

    assert eventually(fn -> render(view) =~ "Destroy the refreshed revision target?" end, 80)
    refreshed_html = render(view)
    assert refreshed_html =~ "Destroy the refreshed revision target?"
    refute refreshed_html =~ "Draft from the old active action"
    refute refreshed_html =~ ~s(name="revision[confirmed]" value="true" checked)

    html =
      render_submit(view, "revise-decision", %{
        "decision_id" => refreshed.decision_id,
        "revision" => %{
          "choice" => "option:ship",
          "confirmed" => "true",
          "reason" => "Confirmed after the retained refresh"
        }
      })

    assert html =~ "Revision recorded"

    assert eventually(fn ->
             {:ok, current} = DecisionStore.get(refreshed.decision_id, store)
             current.revision_sequence == 1
           end)
  end

  test "a direct Decision route resolves once for each LiveView parameter pass" do
    orchestrator_name = Module.concat(__MODULE__, :DirectRouteOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :DirectRouteStore)
    counting_store_name = Module.concat(__MODULE__, :DirectRouteCountingStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 5_071}}}
      end)

    decision = request_dashboard_decision(store, "direct-route")

    start_supervised!({CountingDetailStore, name: counting_store_name, store: decision_store_name})
    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: counting_store_name
    )

    {:ok, _view, _html} = live(build_conn(), "/commands/#{decision.decision_id}")

    assert CountingDetailStore.retained_lookup_count(counting_store_name) == 2
  end

  test "a missing Decision URL stays distinct from a retained-store outage" do
    orchestrator_name = Module.concat(__MODULE__, :MissingRetainedDetailOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :MissingRetainedDetailStore)

    start_decision_store(decision_store_name, fn _decision, _opts -> {:ok, %{status: :accepted, item: %{id: 508}}} end)
    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name
    )

    {:ok, _view, html} = live(build_conn(), "/commands/dec-retained-missing")
    assert html =~ "Command not found"
    assert html =~ "No retained Command matches dec-retained-missing."
    refute html =~ "Command unavailable"
  end
end
