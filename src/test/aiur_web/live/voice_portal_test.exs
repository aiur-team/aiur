defmodule AiurWeb.VoicePortalTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  import AiurWeb.DashboardLiveSupport
  import AiurWeb.DashboardLiveSupport.Processes
  import AiurWeb.DashboardLiveSupport.UnitFixtures

  alias Aiur.TestSupport.EndpointStubs

  @endpoint AiurWeb.Endpoint

  defmodule InstalledPanel do
    @moduledoc false
  end

  setup context do
    identity = units_identity()
    handle = conversation_handle_value("v")
    now = DateTime.utc_now()
    owner = self()
    orchestrator_name = __MODULE__.Orchestrator
    orchestrator = start_counting_orchestrator(orchestrator_name)
    snapshot = freshen(units_conversation_snapshot(identity, handle), now)
    snapshot = if context[:empty_workers], do: %{snapshot | running: []}, else: snapshot
    replace_counting_snapshot(orchestrator, snapshot)
    membership = freshen(units_membership(identity), now)
    membership = if context[:empty_workers], do: %{membership | members: []}, else: membership
    membership = if context[:stale_workers], do: update_in(membership.freshness, &Map.put(&1, :status, :stale)), else: membership
    activity = units_activity(identity)
    activity = if context[:empty_workers], do: %{activity | entries: []}, else: activity

    start_test_endpoint(
      snapshot_timeout_ms: 100,
      control_center_cache: if(context[:missing_cache], do: __MODULE__.MissingCache, else: false),
      dashboard_writable: !context[:read_only],
      browser_basic_auth: true,
      voice_target_payload_fun: fn -> %{fleet: %{running: Enum.map(snapshot.running, &%{issue_identifier: &1.identifier})}} end,
      capabilities_report_fun: fn -> %{capabilities: Map.new(~w(voice.stt voice.tts voice.conversation), &{&1, %{state: :available}})} end,
      units_membership_fun: fn -> membership end,
      units_activity_fun: fn -> activity end,
      live_conversation_resolve_fun: fn selected ->
        send(owner, {:conversation_resolved, selected})
        {:ok, freshen(conversation_snapshot(handle), now)}
      end,
      live_conversation_subscribe_fun: fn selected ->
        send(owner, {:conversation_subscribed, selected})
        :ok
      end,
      live_conversation_unsubscribe_fun: fn selected ->
        send(owner, {:conversation_unsubscribed, selected})
        :ok
      end,
      usage_snapshot_fun: fn _identifier, _opts -> {:error, :no_usage_data} end
    )

    EndpointStubs.put(orchestrator: orchestrator_name, voice_conversation_panel_module: InstalledPanel)

    %{handle: handle}
  end

  test "the new home opens the authenticated voice portal and mounts its controller owner" do
    home = build_conn() |> get("/") |> html_response(200)
    [href] = home |> Floki.parse_document!() |> Floki.find(~s(a[href="/voice"])) |> Floki.attribute("href")
    assert home =~ "Talk to Executor"
    assert home =~ ~s(src="/executor-voice-controller.js")

    {:ok, view, _html} = live(build_conn(), href)
    assert has_element?(view, ~s(#executor-voice-host[phx-hook="ExecutorVoice"]))
    assert has_element?(view, "#executor-voice-prototype[data-executor-voice]")
    assert has_element?(view, "#voice-workers")
    refute has_element?(view, ".units-card")
  end

  test "the prototype retains provider comparison, rating and delivery receipt controls" do
    {:ok, view, _html} = live(build_conn(), "/voice")
    root = "#executor-voice-prototype"
    assert has_element?(view, root <> " select[data-executor-voice-provider]:not([disabled]) option[value=elevenlabs_agents]", "ElevenLabs")
    assert has_element?(view, root <> " select[data-executor-voice-provider] option[value=openai_realtime]", "OpenAI")
    assert has_element?(view, root <> " input[data-executor-voice-model]:not([disabled])")
    assert has_element?(view, root <> " [data-executor-voice-meter][role=status]", "Comparison usage unavailable.")
    assert has_element?(view, root <> " details[data-executor-voice-compare] summary", "Compare providers and record Kevin’s rating")
    assert has_element?(view, root <> " [data-executor-voice-comparisons]")
    assert has_element?(view, root <> " [data-executor-voice-comparison-status][role=status]")
    assert has_element?(view, root <> " [data-executor-voice-receipt][role=status]")
    assert has_element?(view, root <> " button[data-executor-voice-toggle]", "Talk to Executor")
  end

  test "the worker picker opens the retained drawer with typed Dictate and Converse controls", %{handle: handle} do
    {:ok, view, _html} = live(build_conn(), "/voice")
    refute has_element?(view, "#voice-conversation-drawer")
    view |> element(~s(#voice-workers button[phx-click="read-conversation"][aria-label="Open conversation for 1110"])) |> render_click()
    assert_receive {:conversation_resolved, ^handle}, 1_000
    assert_receive {:conversation_subscribed, ^handle}, 1_000
    drawer = "#voice-conversation-drawer"
    assert has_element?(view, drawer <> ~s([phx-hook="ConversationDrawer"][role=dialog]))
    assert has_element?(view, drawer, "Reviewing the drawer")
    assert has_element?(view, drawer <> " textarea[data-voice-input]")
    assert has_element?(view, drawer <> ~s( [data-voice-mode=dictate][aria-disabled=false]))
    assert has_element?(view, drawer <> ~s( [data-voice-mode=converse][aria-disabled=false]))
    [target] = view |> element(drawer <> " [data-voice-root]") |> render() |> Floki.parse_fragment!() |> Floki.attribute("data-voice-target")
    assert Jason.decode!(target) == %{"kind" => "worker", "ticket" => "1110"}
    render_hook(view, "open-voice-conversation", %{"surface" => "agent_composer", "target" => target})
    assert :sys.get_state(view.pid).socket.assigns.voice_conversation_panel == %{target: %{kind: :worker, ticket: "1110", instance_id: nil}, surface: "agent_composer"}
    assert view |> render() |> Floki.parse_fragment!() |> Floki.find("[data-executor-voice]") |> length() == 1
    view |> element(drawer <> ~s( button[phx-click="close-conversation"])) |> render_click()
    assert_receive {:conversation_unsubscribed, ^handle}, 1_000
    refute has_element?(view, drawer)
  end

  @tag read_only: true
  test "read-only viewers retain transcript access while prototype and worker voice writes are disabled" do
    {:ok, view, _html} = live(build_conn(), "/voice")
    assert has_element?(view, "#executor-voice-prototype select[data-executor-voice-provider][disabled]")
    assert has_element?(view, "#executor-voice-prototype input[data-executor-voice-model][disabled]")
    assert has_element?(view, "#executor-voice-prototype button[data-executor-voice-toggle][disabled]")
    view |> element(~s(#voice-workers button[aria-label="Open conversation for 1110"])) |> render_click()
    assert has_element?(view, "#voice-conversation-drawer", "Reviewing the drawer")
    refute has_element?(view, "#voice-conversation-drawer textarea[data-voice-input]")
    refute has_element?(view, "#voice-conversation-drawer [data-voice-mode]")
  end

  test "an unauthenticated request cannot open the voice portal" do
    authorized = build_conn() |> get("/voice") |> html_response(200)
    assert authorized =~ ~s(id="executor-voice-prototype")

    conn = Phoenix.ConnTest.build_conn() |> get("/voice")
    assert conn.status == 401
    assert Plug.Conn.get_resp_header(conn, "www-authenticate") == [~s(Basic realm="Aiur")]
    refute conn.resp_body =~ "executor-voice-prototype"
  end

  @tag missing_cache: true
  test "a failed payload read stays unavailable instead of inventing an empty worker list" do
    {:ok, view, _html} = live(build_conn(), "/voice")
    payload = :sys.get_state(view.pid).socket.assigns.payload
    assert payload.stale == true
    assert payload.fleet.error.code == "snapshot_unavailable"
    refute Map.has_key?(payload, :units)
    assert has_element?(view, "#voice-workers [role=status]", "Worker conversations are unavailable.")
    refute has_element?(view, "#voice-workers", "No workers are listed.")
    refute has_element?(view, "#voice-workers button")
  end

  @tag empty_workers: true
  test "a known empty catalog is rendered as empty rather than unavailable" do
    {:ok, view, _html} = live(build_conn(), "/voice")
    payload = :sys.get_state(view.pid).socket.assigns.payload
    assert payload.units.status == :empty
    assert payload.units.snapshot.rows == []
    assert has_element?(view, "#voice-workers", "No workers are listed.")
    refute has_element?(view, "#voice-workers [role=status]", "Worker conversations are unavailable.")
    refute has_element?(view, "#voice-workers button")
  end

  @tag empty_workers: true, stale_workers: true
  test "a stale empty catalog does not claim a current empty worker list" do
    {:ok, view, _html} = live(build_conn(), "/voice")
    payload = :sys.get_state(view.pid).socket.assigns.payload
    assert payload.units.status == :stale
    assert payload.units.snapshot.rows == []
    assert has_element?(view, "#voice-workers [role=status]", "Worker list is stale")
    refute has_element?(view, "#voice-workers", "No workers are listed.")
    refute has_element?(view, "#voice-workers button")
  end

  defp freshen(%DateTime{}, now), do: now
  defp freshen(%_{} = value, _now), do: value
  defp freshen(value, now) when is_map(value), do: Map.new(value, fn {key, item} -> {key, freshen(item, now)} end)
  defp freshen(value, now) when is_list(value), do: Enum.map(value, &freshen(&1, now))
  defp freshen(value, _now), do: value
end
