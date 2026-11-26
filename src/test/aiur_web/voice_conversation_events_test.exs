defmodule AiurWeb.VoiceConversationEventsTest do
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
    # Installation marker only: this ticket owns the handoff, not panel UI.
  end

  setup do
    identity = units_identity()
    handle = conversation_handle_value("v")
    now = DateTime.utc_now()
    orchestrator = start_counting_orchestrator(__MODULE__.Orchestrator)
    replace_counting_snapshot(orchestrator, freshen(units_conversation_snapshot(identity, handle), now))
    {:ok, capability} = Agent.start_link(fn -> %{state: :available} end)
    {:ok, workers} = Agent.start_link(fn -> ["1110"] end)

    EndpointStubs.put(voice_target_payload_fun: fn -> %{fleet: %{running: Enum.map(Agent.get(workers, & &1), &%{issue_identifier: &1})}} end)

    start_test_endpoint(
      orchestrator: __MODULE__.Orchestrator,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      dashboard_writable: true,
      voice_conversation_panel_module: InstalledPanel,
      capabilities_report_fun: fn -> %{capabilities: %{"voice.conversation" => Agent.get(capability, & &1)}} end,
      units_membership_fun: fn -> freshen(units_membership(identity), now) end,
      units_activity_fun: fn -> units_activity(identity) end,
      live_conversation_resolve_fun: fn ^handle -> {:ok, freshen(conversation_snapshot(handle), now)} end,
      live_conversation_subscribe_fun: fn ^handle -> :ok end,
      live_conversation_unsubscribe_fun: fn ^handle -> :ok end,
      usage_snapshot_fun: fn _identifier, _opts -> {:error, :no_usage_data} end
    )

    {:ok, view, _html} = live(build_conn(), "/voice")
    view |> element(~s(#voice-workers button[aria-label="Open conversation for 1110"])) |> render_click()
    target = view |> element("[data-voice-root]") |> render() |> Floki.parse_fragment!() |> Floki.attribute("data-voice-target") |> hd()
    %{view: view, capability: capability, workers: workers, params: %{"surface" => "agent_composer", "target" => target}}
  end

  test "Converse opens the panel request for the drawer's worker and close clears it", %{view: view, params: params} do
    assert has_element?(view, "[data-voice-mode=converse][aria-disabled=false]")
    assert Jason.decode!(params["target"]) == %{"kind" => "worker", "ticket" => "1110"}
    render_hook(view, "open-voice-conversation", params)
    assert assigns(view).voice_conversation_panel == %{target: %{kind: :worker, ticket: "1110", instance_id: nil}, surface: "agent_composer"}
    assert assigns(view).voice_conversation_error == nil
    render_hook(view, "close-voice-conversation", %{})
    assert assigns(view).voice_conversation_panel == nil
  end

  test "a stopped agent is refused with an inline reason and no panel", %{view: view, params: params, workers: workers} do
    Agent.update(workers, fn _ -> [] end)
    render_hook(view, "open-voice-conversation", params)
    assert assigns(view).voice_conversation_panel == nil
    assert has_element?(view, "[role=dialog] [data-voice-conversation-error=target_not_found]", "Agent is no longer running.")
  end

  test "forged and malformed targets are refused without opening a panel", %{view: view, params: params} do
    for target <- [~s({"kind":"root"}), ~s({"kind":"worker","ticket":"1110","admin":true}), "{", "null", String.duplicate("x", 2049)] do
      render_hook(view, "open-voice-conversation", %{params | "target" => target})
      assert assigns(view).voice_conversation_panel == nil
      assert has_element?(view, "[data-voice-conversation-error=invalid_payload]", "Voice request is invalid.")
    end
  end

  test "capability disabled after render is checked again at click time", %{view: view, params: params, capability: capability} do
    Agent.update(capability, fn _ -> %{state: :unavailable, reason: :disabled} end)
    render_hook(view, "open-voice-conversation", params)
    assert assigns(view).voice_conversation_panel == nil
    assert has_element?(view, "[data-voice-conversation-error=disabled]", "Converse is disabled.")
  end

  test "unavailable and unreadable capabilities never become an available panel", %{view: view, params: params, capability: capability} do
    for {entry, code, copy, reasons} <- [
          {%{state: :unavailable, reason: :not_installed}, "not_installed", "Converse isn't installed", []},
          {%{state: :unavailable, reason: :not_configured}, "not_configured", "Converse is not configured.", []},
          {%{state: :unavailable, reason: :not_running}, "unknown", "Converse availability could not be checked.", [:not_running]},
          {%{state: :unknown}, "unknown", "Converse availability could not be checked.", [:unknown]}
        ] do
      Agent.update(capability, fn _ -> entry end)
      render_hook(view, "open-voice-conversation", params)
      assert assigns(view).voice_conversation_panel == nil
      assert has_element?(view, "[data-voice-conversation-error=#{code}]", copy)
      assert Map.get(assigns(view).voice_conversation_error, :reasons, []) == reasons
    end
  end

  test "Command surfaces and mismatched surfaces cannot open Converse", %{view: view, params: params} do
    for surface <- ["command_response", "command_revision", "conversation_panel", "executor_composer"] do
      render_hook(view, "open-voice-conversation", %{params | "surface" => surface})
      assert assigns(view).voice_conversation_panel == nil
      assert assigns(view).voice_conversation_error.reason_code == "invalid_payload"
    end
  end

  test "degraded capability permits opening and clears an earlier refusal", %{view: view, params: params, capability: capability, workers: workers} do
    Agent.update(workers, fn _ -> [] end)
    render_hook(view, "open-voice-conversation", params)
    assert assigns(view).voice_conversation_error.reason_code == "target_not_found"
    Agent.update(workers, fn _ -> ["1110"] end)
    Agent.update(capability, fn _ -> %{state: :degraded} end)
    render_hook(view, "open-voice-conversation", params)
    assert assigns(view).voice_conversation_panel.target.ticket == "1110"
    refute has_element?(view, "[data-voice-conversation-error]")
  end

  test "an installed host without the downstream panel refuses the handoff", %{view: view, params: params} do
    EndpointStubs.put(voice_conversation_panel_module: __MODULE__.MissingPanel)
    send(view.pid, :elevenlabs_quota_tick)
    render(view)
    assert has_element?(view, "[data-voice-mode=converse][aria-disabled=true]")
    render_hook(view, "open-voice-conversation", params)
    assert assigns(view).voice_conversation_panel == nil
    assert assigns(view).voice_conversation_error.reason_code == "not_installed"
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp freshen(%DateTime{}, now), do: now
  defp freshen(%_{} = value, _now), do: value
  defp freshen(value, now) when is_map(value), do: Map.new(value, fn {key, item} -> {key, freshen(item, now)} end)
  defp freshen(value, now) when is_list(value), do: Enum.map(value, &freshen(&1, now))
  defp freshen(value, _now), do: value
end
