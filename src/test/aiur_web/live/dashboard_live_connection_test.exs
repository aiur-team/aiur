defmodule AiurWeb.DashboardLiveConnectionTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  alias Aiur.DecisionStore
  alias Aiur.TestSupport.EndpointStubs

  @endpoint AiurWeb.Endpoint

  test "dead render of an open human-required Command disables its Decision button" do
    store = Module.concat(__MODULE__, :DecisionStore)
    directory = Aiur.TestSupport.tmp_root!("dashboard-live-connection-decision")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(directory) end)

    start_supervised!(
      {DecisionStore,
       name: store, state_dir: directory, dispatcher: fn _decision, _opts -> {:ok, %{status: :accepted}} end, dispatch_delay_ms: 0, reconcile_delay_ms: 5_000, filesystem_sync_fun: fn -> :ok end}
    )

    assert {:ok, %{decision: decision}} =
             Aiur.DecisionStoreCase.request(
               store,
               %{
                 "source_id" => "dead-render-disabled",
                 "question" => "Should the dashboard render the answer control disabled?",
                 "blocking" => false,
                 "kind" => "architecture",
                 "authority" => "human_required",
                 "reversibility" => "reversible"
               },
               ticket: %{identifier: "AIUR-5149", title: "Commands", url: nil},
               source: %{agent_id: "agent-5149", session_id: "session-5149", event_id: "event-5149"},
               authority_basis: :security
             )

    previous = Application.get_env(:aiur, AiurWeb.Endpoint, [])

    Application.put_env(
      :aiur,
      AiurWeb.Endpoint,
      EndpointStubs.scope(
        Keyword.merge(previous,
          server: false,
          secret_key_base: String.duplicate("s", 64),
          dashboard_writable: true,
          dashboard_auth_required: false,
          decision_store: store,
          control_center_cache: false,
          open_tickets_fun: fn -> %{status: :ready, tickets: []} end
        )
      )
    )

    on_exit(fn -> Application.put_env(:aiur, AiurWeb.Endpoint, previous) end)
    Aiur.TestSupport.start_owned_endpoint!()

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("authorization", "Basic " <> Base.encode64("operator:test-dashboard-secret"))
      |> get("/commands/#{decision.decision_id}")

    assert conn.status == 200
    document = Floki.parse_document!(conn.resp_body)
    button = Floki.find(document, "#decision-answer-form-#{decision.decision_id} button[type=submit]")
    assert [decision_button] = button
    assert Floki.attribute(decision_button, "disabled") != []

    form = Floki.find(document, "#decision-answer-form-#{decision.decision_id}") |> hd()
    assert [defer_button] = Floki.find(form, "button[phx-click=defer-decision]")
    assert Floki.attribute(defer_button, "disabled") != []
    assert [dismiss_button] = Floki.find(form, "button[aria-label='Dismiss blocker']")
    assert Floki.attribute(dismiss_button, "disabled") != []
  end
end
