defmodule AiurWeb.PresenterDurableTest do
  use Aiur.TestSupport

  alias Aiur.Orchestrator
  alias Aiur.RecentMerge
  alias AiurWeb.Presenter

  import AiurWeb.PresenterFixtures

  test "durable history and outcomes remain visible when the orchestrator is unavailable" do
    telemetry_path = Aiur.TestSupport.tmp_root!("presenter-telemetry") <> ".ndjson"
    File.write!(telemetry_path, "")
    on_exit(fn -> File.rm(telemetry_path) end)

    decision = %{
      decision_id: "dec-history",
      ticket: %{identifier: "983", title: "OCC-6", url: nil},
      question: "Ship it?",
      source_version: 1,
      changed_at: "2026-07-12T18:00:00Z",
      change: :requested,
      actor: %{type: :human_operator, id: "operator-1", label: "Operator"},
      choice: nil,
      rationale: nil,
      dispatch_result: nil,
      acknowledgement_result: nil,
      revision_of: nil,
      superseded_by: nil,
      revised?: false
    }

    assert {:ok, merge} =
             RecentMerge.from_github_event(merged_event(),
               live?: false,
               now: ~U[2026-07-12 18:01:00Z]
             )

    payload =
      Presenter.state_payload(Module.concat(__MODULE__, :MissingOrchestrator), 5,
        decision_history_fun: fn -> [decision] end,
        recent_merge_snapshot_fun: fn ->
          %{
            merges: [merge],
            health: :writable,
            reconciliation: %{status: :partial, partial?: true, pages_fetched: 5}
          }
        end,
        telemetry_file_fun: fn -> telemetry_path end
      )

    assert payload.error.code == "orchestrator_unavailable"
    assert payload.decision_history == %{status: :available, entries: [decision], message: nil}
    assert [recent] = payload.recent_merges.entries
    assert recent.number == 42
    assert recent.ticket_id == nil
    assert payload.recent_merges.reconciliation.partial?

    assert %{
             available?: true,
             path: "/analytics",
             message: "Open the separate durable telemetry report."
           } = payload.analytics
  end

  test "renders a stale last-known-good fleet instead of a snapshot error" do
    orchestrator_name = Module.concat(__MODULE__, :StaleFleetOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)

    on_exit(fn ->
      try do
        :sys.resume(pid)
      catch
        :exit, _reason -> :ok
      end

      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    publish_dashboard_snapshot(pid)

    :sys.suspend(pid)
    send(pid, :dispatch_backlog)

    payload = Presenter.state_payload(orchestrator_name, 0)

    refute Map.has_key?(payload, :error)
    assert payload.counts == %{running: 0, retrying: 0, idle: 0}
    assert payload.snapshot_freshness.status == :stale
    assert is_integer(payload.snapshot_freshness.age_seconds)
  end

  test "an unavailable optional provider does not hide the other durable section" do
    payload =
      Presenter.state_payload(Module.concat(__MODULE__, :MissingProvidersOrchestrator), 5,
        decision_history_fun: fn -> raise "offline" end,
        recent_merge_snapshot_fun: fn ->
          %{
            merges: [],
            health: :writable,
            reconciliation: %{status: :complete, partial?: false, pages_fetched: 1}
          }
        end,
        telemetry_file_fun: fn -> "/definitely/missing/telemetry.ndjson" end
      )

    assert payload.decision_history.status == :unavailable
    assert payload.recent_merges.status == :available
    refute payload.analytics.available?
  end

  test "the recent repository merge projection stays bounded" do
    assert {:ok, merge} =
             RecentMerge.from_github_event(merged_event(),
               live?: false,
               now: ~U[2026-07-12 18:01:00Z]
             )

    merges =
      Enum.map(1..51, fn number ->
        %{merge | id: "owner/repo##{number}", number: number, url: "https://github.com/owner/repo/pull/#{number}"}
      end)

    payload =
      Presenter.state_payload(Module.concat(__MODULE__, :MissingBoundedOrchestrator), 5,
        decision_history_fun: fn -> [] end,
        recent_merge_snapshot_fun: fn ->
          %{
            merges: merges,
            health: :writable,
            reconciliation: %{status: :complete, partial?: false, pages_fetched: 1}
          }
        end,
        telemetry_file_fun: fn -> "/definitely/missing/telemetry.ndjson" end
      )

    assert length(payload.recent_merges.entries) == 50
    assert Enum.map(payload.recent_merges.entries, & &1.number) == Enum.to_list(1..50)
  end
end
