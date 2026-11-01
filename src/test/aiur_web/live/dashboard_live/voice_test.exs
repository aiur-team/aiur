defmodule AiurWeb.DashboardLive.VoiceTest do
  use Aiur.TestSupport

  import Aiur.ExtensionsTestSupport
  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest

  alias Aiur.Orchestrator
  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.DashboardLive.VoicePanel

  @endpoint AiurWeb.Endpoint

  defmodule InstalledPanel do
    @moduledoc false
  end

  test "voice conversation pages cap each visible set and compute the page count" do
    workers = for index <- 1..26, do: %{label: "ticket #{index}"}
    first = VoicePanel.page_rows(workers, 0)
    second = VoicePanel.page_rows(workers, 1)

    assert length(first) == 25
    assert second == [%{label: "ticket 26"}]
    assert VoicePanel.page_count(workers) == 2
  end

  # Voice availability comes from the same registry `/api/v1/capabilities`
  # serves, and a key added mid-session is picked up on the 60 s voice tick
  # rather than only after a failed microphone join.
  test "assigns voice capabilities from the registry at mount and refreshes them on the voice tick" do
    orchestrator_name = Module.concat(__MODULE__, :Orchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    unconfigured = %{state: :unavailable, reason: :not_configured}
    {:ok, reports} = Agent.start_link(fn -> unconfigured end)

    report_fun = fn ->
      stt = Agent.get(reports, & &1)
      %{capabilities: %{"voice.stt" => stt, "voice.tts" => stt, "voice.conversation" => stt, "streamdeck" => %{state: :available}}}
    end

    # Named providers need an explicit private override; atoms otherwise enter shared config.
    start_test_endpoint(snapshot_timeout_ms: 5, capabilities_report_fun: report_fun)
    EndpointStubs.put(orchestrator: orchestrator_name, voice_conversation_panel_module: InstalledPanel)
    {:ok, view, _html} = live(build_conn(), "/commands")
    assert voice_capabilities(view) == %{"voice.stt" => unconfigured, "voice.tts" => unconfigured, "voice.conversation" => unconfigured}

    Agent.update(reports, fn _ -> %{state: :available} end)
    send(view.pid, :elevenlabs_quota_tick)
    _rendered = render(view)
    assert voice_capabilities(view) == %{"voice.stt" => %{state: :available}, "voice.tts" => %{state: :available}, "voice.conversation" => %{state: :available}}
  end

  test "an unreadable registry leaves voice capabilities empty rather than guessing" do
    orchestrator_name = Module.concat(__MODULE__, :FailingOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    start_test_endpoint(snapshot_timeout_ms: 5, capabilities_report_fun: fn -> raise "registry unavailable" end)
    EndpointStubs.put(orchestrator: orchestrator_name)
    {:ok, view, _html} = live(build_conn(), "/commands")
    assert voice_capabilities(view) == %{}
  end

  defp voice_capabilities(view), do: :sys.get_state(view.pid).socket.assigns.voice_capabilities
end
